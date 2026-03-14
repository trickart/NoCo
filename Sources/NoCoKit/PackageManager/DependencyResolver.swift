import Foundation
import Synchronization

/// Resolves a dependency tree from root dependencies, producing a flat list for installation.
/// Supports deduplication (hoisting) and nested node_modules for version conflicts.
public final class DependencyResolver: Sendable {
    private let registry: NpmRegistry
    private let lockfile: Lockfile?
    private let installPeerDeps: Bool
    private let onWarning: (@Sendable (String) -> Void)?
    private let state = Mutex<ResolverState>(ResolverState())

    private struct ResolverState {
        /// Resolved packages keyed by installPath (e.g., "node_modules/foo" or "node_modules/bar/node_modules/foo")
        var resolved: [String: ResolvedPackage] = [:]
        /// Top-level packages: name → version for quick compatibility checks
        var topLevel: [String: String] = [:]
        var resolving: Set<String> = []
        var optionalNames: Set<String> = []
        /// Root dependency names not yet resolved — reserves top-level slots
        var pendingRootDeps: Set<String> = []
    }

    public init(registry: NpmRegistry, lockfile: Lockfile? = nil,
                installPeerDeps: Bool = true,
                onWarning: (@Sendable (String) -> Void)? = nil) {
        self.registry = registry
        self.lockfile = lockfile
        self.installPeerDeps = installPeerDeps
        self.onWarning = onWarning
    }

    /// Resolve all dependencies starting from root dependencies.
    /// Returns a flat list of packages to install with their target paths.
    public func resolve(dependencies: [String: String],
                        optionalDependencies: Set<String> = []) async throws -> [ResolvedPackage] {
        try await resolve(
            orderedDependencies: dependencies.map { ($0.key, $0.value) },
            optionalDependencies: optionalDependencies
        )
    }

    /// Resolve dependencies in the specified order.
    public func resolve(orderedDependencies: [(name: String, range: String)],
                        optionalDependencies: Set<String> = []) async throws -> [ResolvedPackage] {
        state.withLock { state in
            state.resolved = [:]
            state.topLevel = [:]
            state.resolving = []
            state.optionalNames = optionalDependencies
            state.pendingRootDeps = Set(orderedDependencies.map(\.name))
        }

        for (name, range) in orderedDependencies {
            if optionalDependencies.contains(name) {
                do {
                    try await resolveDependency(name: name, rangeStr: range, parentInstallPath: nil)
                } catch {
                    onWarning?("WARN: optional dependency \(name)@\(range) failed to resolve, skipping")
                }
            } else {
                try await resolveDependency(name: name, rangeStr: range, parentInstallPath: nil)
            }
        }

        return state.withLock { Array($0.resolved.values) }
    }

    private enum InstallTarget {
        case skip          // Compatible with top-level, dedup
        case topLevel      // Not yet at top level
        case nested(String) // Needs nesting under parent
    }

    private func resolveDependency(name: String, rangeStr: String,
                                    parentInstallPath: String?) async throws {
        // Determine where this package should be installed
        let target = state.withLock { state -> InstallTarget in
            if let topVersion = state.topLevel[name] {
                // Already at top level — check compatibility
                if let range = SemVerRange(rangeStr),
                   let ver = SemVer(topVersion),
                   range.satisfiedBy(ver) {
                    return .skip // Dedup: reuse top-level version
                }
                // Incompatible — nest under parent
                if let parent = parentInstallPath {
                    return .nested("\(parent)/node_modules/\(name)")
                }
                // Root-level conflict — first wins
                return .skip
            }
            // Not yet at top level
            // If this is a transitive dep and a root dep with this name is pending,
            // nest it to keep the top-level slot available for the root dep
            if parentInstallPath != nil && state.pendingRootDeps.contains(name) {
                return .nested("\(parentInstallPath!)/node_modules/\(name)")
            }
            return .topLevel
        }

        let installPath: String
        let isNested: Bool
        switch target {
        case .skip:
            return
        case .topLevel:
            installPath = "node_modules/\(name)"
            isNested = false
            // Root dep resolved — remove from pending
            if parentInstallPath == nil {
                state.withLock { $0.pendingRootDeps.remove(name) }
            }
        case .nested(let path):
            installPath = path
            isNested = true
        }

        // Circular dependency detection + already resolved check
        let shouldSkip = state.withLock { state -> Bool in
            if state.resolved[installPath] != nil { return true }
            if state.resolving.contains(installPath) { return true }
            state.resolving.insert(installPath)
            return false
        }
        if shouldSkip { return }
        defer { state.withLock { _ = $0.resolving.remove(installPath) } }

        // Check lockfile first
        if let lockfile = lockfile {
            let lockKey = installPath
            if let lockedInfo = lockfile.packages[lockKey] {
                guard let range = SemVerRange(rangeStr) else {
                    throw DependencyResolverError.invalidVersionRange(name, rangeStr)
                }
                if let ver = SemVer(lockedInfo.version), range.satisfiedBy(ver) {
                    let isOptional = state.withLock { $0.optionalNames.contains(name) }
                    let pkg = ResolvedPackage(
                        name: name, version: lockedInfo.version,
                        tarballURL: lockedInfo.resolved, integrity: lockedInfo.integrity,
                        dependencies: lockedInfo.dependencies,
                        installPath: installPath,
                        optional: isOptional
                    )
                    state.withLock { state in
                        state.resolved[installPath] = pkg
                        if !isNested {
                            state.topLevel[name] = pkg.version
                        }
                    }

                    // Resolve transitive dependencies
                    for (depName, depRange) in lockedInfo.dependencies {
                        try await resolveDependency(name: depName, rangeStr: depRange,
                                                     parentInstallPath: installPath)
                    }
                    return
                }
            }
        }

        // Fetch from registry
        let metadata = try await registry.fetchMetadata(for: name)

        guard let range = SemVerRange(rangeStr) else {
            throw DependencyResolverError.invalidVersionRange(name, rangeStr)
        }

        // Find best matching version
        let availableVersions = metadata.versions.keys.compactMap { SemVer($0) }
        guard let bestVersion = range.bestMatch(from: availableVersions) else {
            throw DependencyResolverError.noMatchingVersion(name, rangeStr)
        }

        let versionStr = bestVersion.description
        guard let versionInfo = metadata.versions[versionStr] else {
            throw DependencyResolverError.noMatchingVersion(name, rangeStr)
        }

        let isOptional = state.withLock { $0.optionalNames.contains(name) }
        let pkg = ResolvedPackage(
            name: name, version: versionStr,
            tarballURL: versionInfo.dist.tarball,
            integrity: versionInfo.dist.integrity,
            dependencies: versionInfo.dependencies,
            installPath: installPath,
            optional: isOptional
        )
        state.withLock { state in
            state.resolved[installPath] = pkg
            if !isNested {
                state.topLevel[name] = pkg.version
            }
        }

        // Resolve transitive dependencies
        let bundledSet = Set(versionInfo.bundledDependencies)
        for (depName, depRange) in versionInfo.dependencies {
            // bundledDependencies に含まれるものはスキップ（tarball内に同梱済み）
            if bundledSet.contains(depName) { continue }
            try await resolveDependency(name: depName, rangeStr: depRange,
                                         parentInstallPath: installPath)
        }

        // Resolve peerDependencies
        for (peerName, peerRange) in versionInfo.peerDependencies {
            let isOptional = versionInfo.peerDependenciesMeta[peerName]?.optional == true
            try await resolvePeerDependency(
                name: peerName, rangeStr: peerRange,
                requestedBy: name, optional: isOptional,
                parentInstallPath: installPath
            )
        }
    }

    private func resolvePeerDependency(
        name: String, rangeStr: String,
        requestedBy: String, optional: Bool,
        parentInstallPath: String
    ) async throws {
        if !installPeerDeps { return }

        // Peer dependencies always target top level
        let existingCheck = state.withLock { state -> (resolved: Bool, compatible: Bool) in
            guard let topVersion = state.topLevel[name] else { return (false, false) }
            guard let range = SemVerRange(rangeStr),
                  let ver = SemVer(topVersion) else { return (true, true) }
            return (true, range.satisfiedBy(ver))
        }

        if existingCheck.resolved {
            if !existingCheck.compatible && !optional {
                onWarning?("WARN: peer dependency \(name)@\(rangeStr) required by \(requestedBy) conflicts with installed version")
            }
            return
        }

        // Not yet resolved — resolve as a top-level dependency
        do {
            try await resolveDependency(name: name, rangeStr: rangeStr, parentInstallPath: nil)
        } catch {
            if optional {
                return
            }
            throw error
        }
    }
}

/// A resolved package ready for installation
public struct ResolvedPackage: Sendable {
    public let name: String
    public let version: String
    public let tarballURL: String
    public let integrity: String
    public let dependencies: [String: String]
    /// Install path relative to project root (e.g., "node_modules/foo" or "node_modules/bar/node_modules/foo")
    public let installPath: String
    public let optional: Bool

    public init(name: String, version: String, tarballURL: String, integrity: String,
                dependencies: [String: String], installPath: String, optional: Bool = false) {
        self.name = name
        self.version = version
        self.tarballURL = tarballURL
        self.integrity = integrity
        self.dependencies = dependencies
        self.installPath = installPath
        self.optional = optional
    }

    /// Whether this is a nested (non-top-level) package
    public var isNested: Bool {
        // Top-level: "node_modules/foo" or "node_modules/@scope/foo"
        // Nested: "node_modules/bar/node_modules/foo"
        let afterFirst = installPath.dropFirst("node_modules/".count)
        return afterFirst.contains("node_modules/")
    }
}

public enum DependencyResolverError: Error, CustomStringConvertible {
    case invalidVersionRange(String, String)
    case noMatchingVersion(String, String)
    case circularDependency([String])

    public var description: String {
        switch self {
        case .invalidVersionRange(let name, let range):
            return "Invalid version range '\(range)' for package '\(name)'"
        case .noMatchingVersion(let name, let range):
            return "No version matching '\(range)' found for package '\(name)'"
        case .circularDependency(let chain):
            return "Circular dependency detected: \(chain.joined(separator: " → "))"
        }
    }
}

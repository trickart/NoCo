import Foundation
import Synchronization

/// Resolves a dependency tree from root dependencies, producing a flat list for installation.
public final class DependencyResolver: Sendable {
    private let registry: NpmRegistry
    private let lockfile: Lockfile?
    private let installPeerDeps: Bool
    private let onWarning: (@Sendable (String) -> Void)?
    private let state = Mutex<ResolverState>(ResolverState())

    private struct ResolverState {
        var resolved: [String: ResolvedPackage] = [:]
        var resolving: Set<String> = []
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
    public func resolve(dependencies: [String: String]) async throws -> [ResolvedPackage] {
        try await resolve(orderedDependencies: dependencies.map { ($0.key, $0.value) })
    }

    /// Resolve dependencies in the specified order.
    public func resolve(orderedDependencies: [(name: String, range: String)]) async throws -> [ResolvedPackage] {
        state.withLock { state in
            state.resolved = [:]
            state.resolving = []
        }

        for (name, range) in orderedDependencies {
            try await resolveDependency(name: name, rangeStr: range, parentPath: [])
        }

        return state.withLock { Array($0.resolved.values) }
    }

    private func resolveDependency(name: String, rangeStr: String, parentPath: [String]) async throws {
        // Circular dependency detection
        let resolveKey = "\(name)@\(rangeStr)"
        let shouldSkip = state.withLock { state -> Bool in
            if state.resolving.contains(resolveKey) { return true }
            state.resolving.insert(resolveKey)
            return false
        }
        if shouldSkip { return }
        defer { state.withLock { $0.resolving.remove(resolveKey) } }

        // Check if already resolved at top level with compatible version
        let alreadyResolved = state.withLock { state -> Bool in
            guard let existing = state.resolved[name] else { return false }
            guard let range = SemVerRange(rangeStr) else { return true }
            if let existingVer = SemVer(existing.version), range.satisfiedBy(existingVer) {
                return true
            }
            // Incompatible — in a real implementation we'd nest, but for now skip
            return true
        }
        if alreadyResolved { return }

        // Check lockfile first
        if let lockfile = lockfile {
            let lockKey = "node_modules/\(name)"
            if let lockedInfo = lockfile.packages[lockKey] {
                guard let range = SemVerRange(rangeStr) else {
                    throw DependencyResolverError.invalidVersionRange(name, rangeStr)
                }
                if let ver = SemVer(lockedInfo.version), range.satisfiedBy(ver) {
                    let pkg = ResolvedPackage(
                        name: name, version: lockedInfo.version,
                        tarballURL: lockedInfo.resolved, integrity: lockedInfo.integrity,
                        dependencies: lockedInfo.dependencies,
                        installPath: "node_modules/\(name)"
                    )
                    state.withLock { $0.resolved[name] = pkg }

                    // Resolve transitive dependencies
                    for (depName, depRange) in lockedInfo.dependencies {
                        try await resolveDependency(name: depName, rangeStr: depRange, parentPath: parentPath + [name])
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

        let pkg = ResolvedPackage(
            name: name, version: versionStr,
            tarballURL: versionInfo.dist.tarball,
            integrity: versionInfo.dist.integrity,
            dependencies: versionInfo.dependencies,
            installPath: "node_modules/\(name)"
        )
        state.withLock { $0.resolved[name] = pkg }

        // Resolve transitive dependencies
        for (depName, depRange) in versionInfo.dependencies {
            try await resolveDependency(name: depName, rangeStr: depRange, parentPath: parentPath + [name])
        }

        // Resolve peerDependencies
        for (peerName, peerRange) in versionInfo.peerDependencies {
            let isOptional = versionInfo.peerDependenciesMeta[peerName]?.optional == true
            try await resolvePeerDependency(
                name: peerName, rangeStr: peerRange,
                requestedBy: name, optional: isOptional,
                parentPath: parentPath + [name]
            )
        }
    }

    private func resolvePeerDependency(
        name: String, rangeStr: String,
        requestedBy: String, optional: Bool,
        parentPath: [String]
    ) async throws {
        if !installPeerDeps { return }

        let existingCheck = state.withLock { state -> (resolved: Bool, compatible: Bool) in
            guard let existing = state.resolved[name] else { return (false, false) }
            guard let range = SemVerRange(rangeStr),
                  let ver = SemVer(existing.version) else { return (true, true) }
            return (true, range.satisfiedBy(ver))
        }

        if existingCheck.resolved {
            if !existingCheck.compatible && !optional {
                onWarning?("WARN: peer dependency \(name)@\(rangeStr) required by \(requestedBy) conflicts with installed version")
            }
            return
        }

        // Not yet resolved — resolve as a normal dependency
        do {
            try await resolveDependency(name: name, rangeStr: rangeStr, parentPath: parentPath)
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
    public let installPath: String
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

import Foundation
import Synchronization

/// Resolves a dependency tree from root dependencies, producing a flat list for installation.
public final class DependencyResolver: Sendable {
    private let registry: NpmRegistry
    private let lockfile: Lockfile?
    private let state = Mutex<ResolverState>(ResolverState())

    private struct ResolverState {
        var resolved: [String: ResolvedPackage] = [:]
        var resolving: Set<String> = []
    }

    public init(registry: NpmRegistry, lockfile: Lockfile? = nil) {
        self.registry = registry
        self.lockfile = lockfile
    }

    /// Resolve all dependencies starting from root dependencies.
    /// Returns a flat list of packages to install with their target paths.
    public func resolve(dependencies: [String: String]) async throws -> [ResolvedPackage] {
        state.withLock { state in
            state.resolved = [:]
            state.resolving = []
        }

        for (name, range) in dependencies {
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

import Testing
import Foundation
import Synchronization
@testable import NoCoKit

@Suite("DependencyResolver Tests")
struct DependencyResolverTests {

    @Test("Resolve from lockfile")
    func resolveFromLockfile() async throws {
        let registry = NpmRegistry()
        var lockfile = Lockfile(name: "test", version: "1.0.0")
        lockfile.packages["node_modules/is-number"] = LockfilePackageInfo(
            version: "7.0.0",
            resolved: "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
            integrity: "sha512-test"
        )

        let resolver = DependencyResolver(registry: registry, lockfile: lockfile)
        let resolved = try await resolver.resolve(dependencies: ["is-number": "^7.0.0"])

        #expect(resolved.count == 1)
        #expect(resolved[0].name == "is-number")
        #expect(resolved[0].version == "7.0.0")
    }

    @Test("Lockfile version mismatch falls through to registry")
    func lockfileVersionMismatch() async throws {
        let registry = NpmRegistry()
        var lockfile = Lockfile(name: "test", version: "1.0.0")
        // Version 6.0.0 doesn't satisfy ^7.0.0
        lockfile.packages["node_modules/is-number"] = LockfilePackageInfo(
            version: "6.0.0",
            resolved: "https://example.com/fake.tgz",
            integrity: "sha512-test"
        )

        let resolver = DependencyResolver(registry: registry, lockfile: lockfile)
        // This will hit the real registry since lockfile version doesn't match
        let resolved = try await resolver.resolve(dependencies: ["is-number": "^7.0.0"])

        #expect(resolved.count == 1)
        #expect(resolved[0].name == "is-number")
        #expect(resolved[0].version.hasPrefix("7."))
    }

    // MARK: - peerDependencies Tests

    @Test("peerDependencies are auto-installed from registry")
    func peerDependenciesAutoInstalled() async throws {
        // react-dom has react as a peerDependency
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry)
        let resolved = try await resolver.resolve(dependencies: ["react-dom": "^18.0.0"])

        let names = Set(resolved.map(\.name))
        #expect(names.contains("react-dom"))
        #expect(names.contains("react"), "react should be auto-installed as a peerDependency of react-dom")
    }

    @Test("peerDependencies skipped with legacy-peer-deps")
    func legacyPeerDepsSkipsPeerDependencies() async throws {
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry, installPeerDeps: false)
        let resolved = try await resolver.resolve(dependencies: ["react-dom": "^18.0.0"])

        let names = Set(resolved.map(\.name))
        #expect(names.contains("react-dom"))
        // react should NOT be installed since we're skipping peer deps
        // (react-dom lists react as peerDependency, not regular dependency)
        #expect(!names.contains("react"), "react should not be installed when legacy-peer-deps is set")
    }

    @Test("peerDependency already resolved as dependency does not duplicate")
    func peerDependencyAlreadyResolved() async throws {
        // If react is already a direct dependency, react-dom's peerDep on react should not conflict
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry)
        let resolved = try await resolver.resolve(dependencies: [
            "react": "^18.0.0",
            "react-dom": "^18.0.0"
        ])

        let reactCount = resolved.filter { $0.name == "react" }.count
        #expect(reactCount == 1, "react should appear exactly once even when both direct and peer dependency")
    }

    @Test("Conflicting peerDependency emits warning")
    func conflictingPeerDependencyWarning() async throws {
        let registry = NpmRegistry()
        let warnings = Mutex<[String]>([])

        // Pin react@17 via lockfile. Use orderedDependencies to ensure
        // react@17 resolves before react-dom@18 (which has react@^18 as peerDep).
        var lockfile = Lockfile(name: "test", version: "1.0.0")
        lockfile.packages["node_modules/react"] = LockfilePackageInfo(
            version: "17.0.2",
            resolved: "https://registry.npmjs.org/react/-/react-17.0.2.tgz",
            integrity: "sha512-test"
        )

        let resolver = DependencyResolver(
            registry: registry, lockfile: lockfile,
            onWarning: { msg in
                warnings.withLock { $0.append(msg) }
            }
        )
        _ = try await resolver.resolve(orderedDependencies: [
            (name: "react", range: "^17.0.0"),
            (name: "react-dom", range: "^18.0.0"),
        ])

        let hasConflictWarning = warnings.withLock { $0.contains { $0.contains("peer dependency") && $0.contains("react") } }
        #expect(hasConflictWarning, "Should warn about conflicting peer dependency for react")
    }
}

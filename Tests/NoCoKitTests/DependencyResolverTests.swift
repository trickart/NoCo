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

    // MARK: - optionalDependencies Tests

    @Test("optionalDependencies are resolved normally")
    func optionalDependenciesResolved() async throws {
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry)
        let resolved = try await resolver.resolve(
            dependencies: ["is-number": "^7.0.0"],
            optionalDependencies: ["is-number"]
        )

        #expect(resolved.count == 1)
        #expect(resolved[0].name == "is-number")
        #expect(resolved[0].optional == true)
    }

    @Test("Failed optionalDependency is skipped without error")
    func failedOptionalDependencySkipped() async throws {
        let registry = NpmRegistry()
        let warnings = Mutex<[String]>([])
        let resolver = DependencyResolver(
            registry: registry,
            onWarning: { msg in
                warnings.withLock { $0.append(msg) }
            }
        )

        // non-existent package as optional dep should not throw
        let resolved = try await resolver.resolve(
            dependencies: [
                "is-number": "^7.0.0",
                "this-package-does-not-exist-xyz-123": "^1.0.0"
            ],
            optionalDependencies: ["this-package-does-not-exist-xyz-123"]
        )

        let names = Set(resolved.map(\.name))
        #expect(names.contains("is-number"), "Required dependency should still be installed")
        #expect(!names.contains("this-package-does-not-exist-xyz-123"), "Failed optional dep should be skipped")

        let hasWarning = warnings.withLock { $0.contains { $0.contains("optional dependency") } }
        #expect(hasWarning, "Should emit warning for failed optional dependency")
    }

    // MARK: - bundledDependencies Tests

    @Test("bundledDependencies are skipped during dependency resolution")
    func bundledDependenciesSkipped() async throws {
        // npm package with bundledDependencies should not resolve those as transitive deps
        // We use a mock-like approach: resolve a package that has bundledDependencies in its metadata
        // For a real-world test, we use `npm` package itself which has bundledDependencies
        let registry = NpmRegistry()
        let metadata = try await registry.fetchMetadata(for: "npm")
        let latestVersion = metadata.distTags["latest"]!
        let versionInfo = metadata.versions[latestVersion]!

        // Verify that npm actually has bundledDependencies in its metadata
        #expect(!versionInfo.bundledDependencies.isEmpty, "npm package should have bundledDependencies")

        // Now resolve npm - bundled deps should NOT appear in resolved list
        let resolver = DependencyResolver(registry: registry)
        let resolved = try await resolver.resolve(dependencies: ["npm": latestVersion])

        let resolvedNames = Set(resolved.map(\.name))
        for bundledName in versionInfo.bundledDependencies {
            #expect(!resolvedNames.contains(bundledName),
                    "\(bundledName) is bundled and should not be in resolved list")
        }
    }

    // MARK: - Deduplication / Nesting Tests

    @Test("Compatible transitive deps are deduplicated to top level")
    func compatibleDepsDeduped() async throws {
        // Install a package with transitive deps — all compatible versions should be at top level
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry)
        let resolved = try await resolver.resolve(dependencies: ["is-number": "^7.0.0"])

        // All packages should be at top level (no nesting for compatible versions)
        for pkg in resolved {
            #expect(!pkg.isNested, "\(pkg.name) should be at top level, but is at \(pkg.installPath)")
        }
    }

    @Test("Incompatible transitive deps are nested under parent")
    func incompatibleDepsNested() async throws {
        // Use lockfile to pin a package at top level, then install another package
        // that needs an incompatible version — it should be nested
        let registry = NpmRegistry()
        var lockfile = Lockfile(name: "test", version: "1.0.0")
        // Pin ms@1.0.0 at top level
        lockfile.packages["node_modules/ms"] = LockfilePackageInfo(
            version: "1.0.0",
            resolved: "https://registry.npmjs.org/ms/-/ms-1.0.0.tgz",
            integrity: "sha512-test"
        )

        let resolver = DependencyResolver(registry: registry, lockfile: lockfile)
        // ms@1.0.0 is pinned. debug@4.x needs ms@^2.0.0 which is incompatible.
        let resolved = try await resolver.resolve(orderedDependencies: [
            (name: "ms", range: "1.0.0"),
            (name: "debug", range: "^4.0.0"),
        ])

        // ms@1.0.0 should be at top level
        let topMs = resolved.first { $0.name == "ms" && !$0.isNested }
        #expect(topMs != nil, "ms@1.0.0 should be at top level")
        #expect(topMs?.version == "1.0.0")

        // debug should need ms@^2.1.3, which is incompatible with ms@1.0.0
        // The nested ms should be a different version from top-level ms@1.0.0
        let nestedMs = resolved.filter { $0.name == "ms" && $0.isNested }
        #expect(!nestedMs.isEmpty, "ms should be nested under debug, all ms: \(resolved.filter { $0.name == "ms" }.map { "\($0.version) at \($0.installPath)" })")
        if let nested = nestedMs.first {
            #expect(nested.version != "1.0.0", "Nested ms should not be 1.0.0")
            #expect(nested.installPath.contains("debug/node_modules/ms"),
                    "Nested ms should be under debug's node_modules, got \(nested.installPath)")
        }
    }

    @Test("Lockfile records nested packages with correct paths")
    func lockfileNestedPaths() async throws {
        let registry = NpmRegistry()
        var lockfile = Lockfile(name: "test", version: "1.0.0")
        lockfile.packages["node_modules/ms"] = LockfilePackageInfo(
            version: "1.0.0",
            resolved: "https://registry.npmjs.org/ms/-/ms-1.0.0.tgz",
            integrity: "sha512-test"
        )

        let resolver = DependencyResolver(registry: registry, lockfile: lockfile)
        let resolved = try await resolver.resolve(orderedDependencies: [
            (name: "ms", range: "1.0.0"),
            (name: "debug", range: "^4.0.0"),
        ])

        // Build lockfile from resolved packages
        var newLockfile = Lockfile(name: "test", version: "1.0.0")
        for pkg in resolved {
            newLockfile.addPackage(pkg)
        }

        // Top-level ms
        #expect(newLockfile.packages["node_modules/ms"] != nil, "Top-level ms should be in lockfile")
        // Nested ms under debug
        let nestedKey = resolved.first { $0.name == "ms" && $0.isNested }?.installPath
        if let key = nestedKey {
            #expect(newLockfile.packages[key] != nil, "Nested ms should be in lockfile at \(key)")
        }
    }

    @Test("Failed required dependency still throws")
    func failedRequiredDependencyThrows() async throws {
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry)

        await #expect(throws: Error.self) {
            _ = try await resolver.resolve(dependencies: [
                "this-package-does-not-exist-xyz-123": "^1.0.0"
            ])
        }
    }
}

import Testing
import Foundation
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
}

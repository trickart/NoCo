import Testing
import Foundation
@testable import NoCoKit

@Suite("Lockfile Tests")
struct LockfileTests {

    @Test("Create and write lockfile")
    func createAndWrite() throws {
        var lockfile = Lockfile(name: "test-project", version: "1.0.0")
        lockfile.setRoot(
            name: "test-project",
            version: "1.0.0",
            dependencies: ["lodash": "^4.17.0"]
        )
        lockfile.addPackage(ResolvedPackage(
            name: "lodash",
            version: "4.17.21",
            tarballURL: "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
            integrity: "sha512-test",
            dependencies: [:],
            installPath: "node_modules/lodash"
        ))

        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = tempDir + "/package-lock.json"
        try lockfile.write(to: path)

        // Re-read and verify
        let reread = try Lockfile.read(from: path)
        #expect(reread.name == "test-project")
        #expect(reread.lockfileVersion == 3)
        #expect(reread.packages["node_modules/lodash"] != nil)

        let lodashInfo = reread.packages["node_modules/lodash"]!
        #expect(lodashInfo.version == "4.17.21")
        #expect(lodashInfo.integrity == "sha512-test")
    }

    @Test("Parse existing lockfile")
    func parseExisting() throws {
        let json = """
        {
          "name": "my-app",
          "version": "1.0.0",
          "lockfileVersion": 3,
          "requires": true,
          "packages": {
            "": {
              "name": "my-app",
              "version": "1.0.0",
              "dependencies": {
                "is-number": "^7.0.0"
              }
            },
            "node_modules/is-number": {
              "version": "7.0.0",
              "resolved": "https://registry.npmjs.org/is-number/-/is-number-7.0.0.tgz",
              "integrity": "sha512-abc123"
            }
          }
        }
        """.data(using: .utf8)!

        let lockfile = try Lockfile.parse(json)
        #expect(lockfile.name == "my-app")
        #expect(lockfile.packages.count == 2)
        #expect(lockfile.packages["node_modules/is-number"]?.version == "7.0.0")
    }

    @Test("Root entry in lockfile")
    func rootEntry() {
        var lockfile = Lockfile()
        lockfile.setRoot(name: "test", version: "2.0.0",
                         dependencies: ["a": "^1.0.0"],
                         devDependencies: ["b": "^2.0.0"])

        let root = lockfile.packages[""]
        #expect(root != nil)
        #expect(root?.name == "test")
        #expect(root?.dependencies["a"] == "^1.0.0")
    }
}

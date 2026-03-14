import Testing
import Foundation
@testable import NoCoKit

@Suite("PackageJson Tests")
struct PackageJsonTests {

    @Test("Parse basic package.json")
    func parseBasic() throws {
        let json = """
        {
          "name": "my-app",
          "version": "1.0.0",
          "dependencies": {
            "lodash": "^4.17.0"
          },
          "devDependencies": {
            "jest": "^29.0.0"
          }
        }
        """.data(using: .utf8)!

        let pkg = try PackageJson.parse(json)
        #expect(pkg.name == "my-app")
        #expect(pkg.version == "1.0.0")
        #expect(pkg.dependencies == ["lodash": "^4.17.0"])
        #expect(pkg.devDependencies == ["jest": "^29.0.0"])
    }

    @Test("Parse minimal package.json")
    func parseMinimal() throws {
        let json = """
        {
          "name": "test"
        }
        """.data(using: .utf8)!

        let pkg = try PackageJson.parse(json)
        #expect(pkg.name == "test")
        #expect(pkg.version == "1.0.0")
        #expect(pkg.dependencies.isEmpty)
        #expect(pkg.devDependencies.isEmpty)
    }

    @Test("Add dependency")
    func addDependency() {
        var pkg = PackageJson(name: "test")
        pkg.addDependency(name: "express", version: "^4.18.0")
        #expect(pkg.dependencies["express"] == "^4.18.0")
    }

    @Test("Add devDependency")
    func addDevDependency() {
        var pkg = PackageJson(name: "test")
        pkg.addDependency(name: "jest", version: "^29.0.0", dev: true)
        #expect(pkg.devDependencies["jest"] == "^29.0.0")
        #expect(pkg.dependencies.isEmpty)
    }

    @Test("Write and re-read package.json")
    func writeAndRead() throws {
        var pkg = PackageJson(name: "roundtrip-test", version: "2.0.0")
        pkg.addDependency(name: "express", version: "^4.18.0")
        pkg.addDependency(name: "jest", version: "^29.0.0", dev: true)

        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = tempDir + "/package.json"
        try pkg.write(to: path)

        let reread = try PackageJson.read(from: path)
        #expect(reread.name == "roundtrip-test")
        #expect(reread.version == "2.0.0")
        #expect(reread.dependencies["express"] == "^4.18.0")
        #expect(reread.devDependencies["jest"] == "^29.0.0")
    }

    @Test("Invalid format throws")
    func invalidFormat() {
        let data = "not json".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try PackageJson.parse(data)
        }
    }
}

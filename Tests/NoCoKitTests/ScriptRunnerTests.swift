import Testing
import Foundation
import Synchronization
@testable import NoCoKit

@Suite("ScriptRunner Tests")
struct ScriptRunnerTests {

    // MARK: - ScriptPolicy Tests

    @Test func denyAllPolicyBlocksAllPackages() {
        let runner = ScriptRunner(policy: .denyAll)
        #expect(!runner.isAllowed(packageName: "lodash"))
        #expect(!runner.isAllowed(packageName: "express"))
    }

    @Test func allowAllPolicyAllowsAllPackages() {
        let runner = ScriptRunner(policy: .allowAll)
        #expect(runner.isAllowed(packageName: "lodash"))
        #expect(runner.isAllowed(packageName: "express"))
    }

    @Test func allowListPolicyAllowsOnlyListedPackages() {
        let runner = ScriptRunner(policy: .allowList(["esbuild", "sharp"]))
        #expect(runner.isAllowed(packageName: "esbuild"))
        #expect(runner.isAllowed(packageName: "sharp"))
        #expect(!runner.isAllowed(packageName: "lodash"))
    }

    // MARK: - readScripts Tests

    @Test func readScriptsFromPackageJson() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let packageJson: [String: Any] = [
            "name": "test-pkg",
            "version": "1.0.0",
            "scripts": [
                "preinstall": "echo pre",
                "install": "echo install",
                "postinstall": "echo post"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: packageJson)
        try data.write(to: URL(fileURLWithPath: (tmpDir as NSString).appendingPathComponent("package.json")))

        let runner = ScriptRunner(policy: .allowAll)
        let info = runner.readScripts(packageDir: tmpDir, name: "test-pkg", version: "1.0.0")

        #expect(info != nil)
        #expect(info?.preinstall == "echo pre")
        #expect(info?.install == "echo install")
        #expect(info?.postinstall == "echo post")
        #expect(info?.hasScripts == true)
    }

    @Test func readScriptsReturnsNilWhenNoLifecycleScripts() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let packageJson: [String: Any] = [
            "name": "test-pkg",
            "version": "1.0.0",
            "scripts": [
                "test": "jest",
                "build": "tsc"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: packageJson)
        try data.write(to: URL(fileURLWithPath: (tmpDir as NSString).appendingPathComponent("package.json")))

        let runner = ScriptRunner(policy: .allowAll)
        let info = runner.readScripts(packageDir: tmpDir, name: "test-pkg", version: "1.0.0")

        #expect(info == nil)
    }

    @Test func readScriptsReturnsNilWhenNoScriptsField() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let packageJson: [String: Any] = [
            "name": "test-pkg",
            "version": "1.0.0"
        ]
        let data = try JSONSerialization.data(withJSONObject: packageJson)
        try data.write(to: URL(fileURLWithPath: (tmpDir as NSString).appendingPathComponent("package.json")))

        let runner = ScriptRunner(policy: .allowAll)
        let info = runner.readScripts(packageDir: tmpDir, name: "test-pkg", version: "1.0.0")

        #expect(info == nil)
    }

    // MARK: - runScripts Tests

    @Test func runScriptsExecutesInOrder() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let outputFile = (tmpDir as NSString).appendingPathComponent("output.txt")

        let info = ScriptInfo(
            packageName: "test-pkg",
            version: "1.0.0",
            preinstall: "echo preinstall >> output.txt",
            install: "echo install >> output.txt",
            postinstall: "echo postinstall >> output.txt"
        )

        let runner = ScriptRunner(policy: .allowAll)
        try runner.runScripts(for: info, packageDir: tmpDir)

        let output = try String(contentsOfFile: outputFile, encoding: .utf8)
        let lines = output.split(separator: "\n").map { String($0) }
        #expect(lines == ["preinstall", "install", "postinstall"])
    }

    @Test func runScriptsThrowsOnFailure() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let info = ScriptInfo(
            packageName: "test-pkg",
            version: "1.0.0",
            preinstall: nil,
            install: nil,
            postinstall: "exit 1"
        )

        let runner = ScriptRunner(policy: .allowAll)
        #expect(throws: ScriptRunnerError.self) {
            try runner.runScripts(for: info, packageDir: tmpDir)
        }
    }

    // MARK: - processPackages Tests

    @Test func processPackagesSkipsWhenDenyAll() throws {
        let tmpDir = NSTemporaryDirectory() + "script-test-\(UUID().uuidString)"
        let nodeModules = (tmpDir as NSString).appendingPathComponent("node_modules")
        let pkgDir = (nodeModules as NSString).appendingPathComponent("test-pkg")
        try FileManager.default.createDirectory(atPath: pkgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Write a package.json with a postinstall that would create a marker file
        let markerFile = (pkgDir as NSString).appendingPathComponent("marker.txt")
        let packageJson: [String: Any] = [
            "name": "test-pkg",
            "version": "1.0.0",
            "scripts": [
                "postinstall": "touch marker.txt"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: packageJson)
        try data.write(to: URL(fileURLWithPath: (pkgDir as NSString).appendingPathComponent("package.json")))

        let messages = Mutex<[String]>([])
        let runner = ScriptRunner(policy: .denyAll) { msg in
            messages.withLock { $0.append(msg) }
        }

        let packages = [ResolvedPackage(
            name: "test-pkg", version: "1.0.0",
            tarballURL: "", integrity: "",
            dependencies: [:], installPath: "node_modules/test-pkg"
        )]

        let scripts = try runner.processPackages(packages, nodeModulesDir: nodeModules)

        // Script should NOT have been executed
        #expect(!FileManager.default.fileExists(atPath: markerFile))
        // But we should have found the scripts
        #expect(scripts.count == 1)
        // Should have warning messages
        #expect(messages.withLock { $0.contains { $0.contains("not run") } })
    }

    // MARK: - ScriptInfo Tests

    @Test func orderedScriptsReturnsCorrectOrder() {
        let info = ScriptInfo(
            packageName: "pkg",
            version: "1.0.0",
            preinstall: "echo pre",
            install: nil,
            postinstall: "echo post"
        )

        let ordered = info.orderedScripts
        #expect(ordered.count == 2)
        #expect(ordered[0].phase == "preinstall")
        #expect(ordered[1].phase == "postinstall")
    }
}

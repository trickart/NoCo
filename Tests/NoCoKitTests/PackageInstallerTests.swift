import Testing
import Foundation
@testable import NoCoKit

@Suite("PackageInstaller .bin symlink tests")
struct PackageInstallerTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "noco-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePackageJson(at dir: String, content: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: content)
        try data.write(to: URL(fileURLWithPath: "\(dir)/package.json"))
    }

    private func writeFile(at path: String, content: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("辞書形式の bin フィールドでシンボリックリンクが作成される")
    func binDictFormat() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/eslint", content: [
            "name": "eslint",
            "version": "8.0.0",
            "bin": ["eslint": "./bin/eslint.js"]
        ])
        try writeFile(at: "\(nodeModules)/eslint/bin/eslint.js", content: "#!/usr/bin/env node\nconsole.log('eslint')\n")

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "eslint", version: "8.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let linkPath = "\(nodeModules)/.bin/eslint"
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == "../eslint/bin/eslint.js")
    }

    @Test("文字列形式の bin フィールドでパッケージ名がコマンド名になる")
    func binStringFormat() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/cowsay", content: [
            "name": "cowsay",
            "version": "1.0.0",
            "bin": "./bin/cli.js"
        ])
        try writeFile(at: "\(nodeModules)/cowsay/bin/cli.js", content: "#!/usr/bin/env node\n")

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "cowsay", version: "1.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let linkPath = "\(nodeModules)/.bin/cowsay"
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == "../cowsay/bin/cli.js")
    }

    @Test("スコープ付きパッケージの bin リンクが正しく作成される")
    func scopedPackageBin() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/@babel/core", content: [
            "name": "@babel/core",
            "version": "7.0.0",
            "bin": ["babel": "./bin/babel.js"]
        ])
        try writeFile(at: "\(nodeModules)/@babel/core/bin/babel.js", content: "#!/usr/bin/env node\n")

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "@babel/core", version: "7.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let linkPath = "\(nodeModules)/.bin/babel"
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == "../@babel/core/bin/babel.js")
    }

    @Test("bin ターゲットファイルに実行権限が付与される")
    func binFilePermissions() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/tool", content: [
            "name": "tool",
            "version": "1.0.0",
            "bin": ["tool": "./cli.js"]
        ])
        let cliPath = "\(nodeModules)/tool/cli.js"
        try writeFile(at: cliPath, content: "#!/usr/bin/env node\n")

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "tool", version: "1.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let attrs = try FileManager.default.attributesOfItem(atPath: cliPath)
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(perms & 0o111 != 0, "bin target should be executable")
    }

    @Test("bin フィールドがないパッケージはスキップされる")
    func noBinField() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/lodash", content: [
            "name": "lodash",
            "version": "4.0.0"
        ])

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "lodash", version: "4.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let binDir = "\(nodeModules)/.bin"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: binDir)) ?? []
        #expect(contents.isEmpty)
    }

    @Test("スコープ付きパッケージの文字列形式 bin はスコープなしの名前がコマンドになる")
    func scopedStringBin() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let nodeModules = "\(tmpDir)/node_modules"
        try writePackageJson(at: "\(nodeModules)/@scope/cli-tool", content: [
            "name": "@scope/cli-tool",
            "version": "1.0.0",
            "bin": "./index.js"
        ])
        try writeFile(at: "\(nodeModules)/@scope/cli-tool/index.js", content: "#!/usr/bin/env node\n")

        let registry = NpmRegistry()
        let installer = PackageInstaller(registry: registry, projectDir: tmpDir)
        let packages = [ResolvedPackage(name: "@scope/cli-tool", version: "1.0.0", tarballURL: "", integrity: "", dependencies: [:], installPath: "")]

        installer.createBinLinks(nodeModulesDir: nodeModules, packages: packages)

        let linkPath = "\(nodeModules)/.bin/cli-tool"
        #expect(FileManager.default.fileExists(atPath: linkPath))

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        #expect(dest == "../@scope/cli-tool/index.js")
    }
}

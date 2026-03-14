import Foundation
import CryptoKit
import Synchronization

/// Downloads, extracts, and installs npm packages into node_modules.
public final class PackageInstaller: Sendable {
    private let registry: NpmRegistry
    private let projectDir: String
    private let maxConcurrency: Int
    private let onProgress: (@Sendable (String) -> Void)?

    public init(registry: NpmRegistry, projectDir: String, maxConcurrency: Int = 8,
                onProgress: (@Sendable (String) -> Void)? = nil) {
        self.registry = registry
        self.projectDir = projectDir
        self.maxConcurrency = maxConcurrency
        self.onProgress = onProgress
    }

    /// Install a list of resolved packages
    public func install(packages: [ResolvedPackage], scriptRunner: ScriptRunner? = nil) async throws {
        let nodeModulesDir = (projectDir as NSString).appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(atPath: nodeModulesDir, withIntermediateDirectories: true)

        // Sort: top-level packages first, nested packages after their parents
        let sorted = packages.sorted { a, b in
            a.installPath.components(separatedBy: "node_modules").count <
            b.installPath.components(separatedBy: "node_modules").count
        }
        let topLevel = sorted.filter { !$0.isNested }
        let nested = sorted.filter { $0.isNested }

        let total = packages.count
        let progress = InstallProgress(total: total, onProgress: onProgress)

        // Phase 1: Install top-level packages concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            var index = 0

            while index < topLevel.count {
                if running >= maxConcurrency {
                    try await group.next()
                    running -= 1
                }

                let pkg = topLevel[index]
                index += 1
                running += 1

                group.addTask {
                    do {
                        try await self.installPackage(pkg, nodeModulesDir: nodeModulesDir)
                    } catch {
                        if pkg.optional {
                            self.onProgress?("warning: optional dependency \(pkg.name)@\(pkg.version) failed to install, skipping")
                            return
                        }
                        throw error
                    }
                    progress.report(pkg)
                }
            }

            try await group.waitForAll()
        }

        // Phase 2: Install nested packages (parents are now in place)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            var index = 0

            while index < nested.count {
                if running >= maxConcurrency {
                    try await group.next()
                    running -= 1
                }

                let pkg = nested[index]
                index += 1
                running += 1

                group.addTask {
                    do {
                        try await self.installPackage(pkg, nodeModulesDir: nodeModulesDir)
                    } catch {
                        if pkg.optional {
                            self.onProgress?("warning: optional dependency \(pkg.name)@\(pkg.version) failed to install, skipping")
                            return
                        }
                        throw error
                    }
                    progress.report(pkg)
                }
            }

            try await group.waitForAll()
        }

        // Create .bin symlinks for packages with bin fields
        createBinLinks(nodeModulesDir: nodeModulesDir, packages: packages)

        // Run lifecycle scripts after all packages are downloaded and extracted
        if let runner = scriptRunner {
            try runner.processPackages(packages, nodeModulesDir: nodeModulesDir)
        }
    }

    /// Create .bin symlinks for packages that declare bin fields in their package.json
    func createBinLinks(nodeModulesDir: String, packages: [ResolvedPackage]) {
        let binDir = (nodeModulesDir as NSString).appendingPathComponent(".bin")
        let fm = FileManager.default

        // Create .bin directory
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)

        for pkg in packages {
            // Only create .bin links for top-level packages
            guard !pkg.isNested else { continue }
            let pkgDir = (nodeModulesDir as NSString).appendingPathComponent(pkg.name)
            let pkgJsonPath = (pkgDir as NSString).appendingPathComponent("package.json")

            guard let data = try? Data(contentsOf: URL(fileURLWithPath: pkgJsonPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let binEntries = parseBinField(json: json, packageName: pkg.name)
            for (command, binPath) in binEntries {
                // Build relative symlink target: ../<pkg-name>/<bin-path>
                let cleanBinPath = binPath.hasPrefix("./") ? String(binPath.dropFirst(2)) : binPath
                let relativeTarget: String
                if pkg.name.contains("/") {
                    // Scoped package: ../@scope/name/<bin-path>
                    relativeTarget = "../\(pkg.name)/\(cleanBinPath)"
                } else {
                    relativeTarget = "../\(pkg.name)/\(cleanBinPath)"
                }

                let linkPath = (binDir as NSString).appendingPathComponent(command)

                // Remove existing link
                try? fm.removeItem(atPath: linkPath)

                // Create symlink
                do {
                    try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: relativeTarget)
                    // Set executable permission on the target file
                    let targetAbsPath = (pkgDir as NSString).appendingPathComponent(cleanBinPath)
                    if fm.fileExists(atPath: targetAbsPath) {
                        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetAbsPath)
                    }
                } catch {
                    // Non-fatal: log and continue
                    onProgress?("warning: failed to create bin link for \(command): \(error)")
                }
            }
        }
    }

    /// Parse the bin field from package.json
    /// Supports: string form ("bin": "./cli.js") and object form ("bin": {"cmd": "./cli.js"})
    private func parseBinField(json: [String: Any], packageName: String) -> [(String, String)] {
        if let binDict = json["bin"] as? [String: String] {
            return Array(binDict)
        }
        if let binString = json["bin"] as? String {
            // Use the package name (without scope) as the command name
            let commandName: String
            if packageName.contains("/") {
                commandName = String(packageName.split(separator: "/").last ?? Substring(packageName))
            } else {
                commandName = packageName
            }
            return [(commandName, binString)]
        }
        return []
    }

    private func installPackage(_ pkg: ResolvedPackage, nodeModulesDir: String) async throws {
        // Derive target directory from installPath (supports nested node_modules)
        // installPath is like "node_modules/foo" or "node_modules/bar/node_modules/foo"
        let projectDir = (nodeModulesDir as NSString).deletingLastPathComponent
        let targetDir = (projectDir as NSString).appendingPathComponent(pkg.installPath)
        // Ensure parent directories exist (handles scoped packages and nested node_modules)
        let parentDir = (targetDir as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        // Skip if already installed with correct version
        let packageJsonPath = (targetDir as NSString).appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: packageJsonPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let installedVersion = json["version"] as? String,
           installedVersion == pkg.version {
            return
        }

        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Download tarball
        let tarballPath = tempDir + "/package.tgz"
        try await registry.downloadTarball(url: pkg.tarballURL, to: tarballPath)

        // Verify integrity if available
        if !pkg.integrity.isEmpty {
            try verifyIntegrity(filePath: tarballPath, expected: pkg.integrity)
        }

        // Extract tarball
        let extractDir = tempDir + "/extracted"
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xzf", tarballPath, "-C", extractDir]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PackageInstallerError.extractionFailed(pkg.name)
        }

        // Move package/ to target
        let extractedPackageDir = extractDir + "/package"
        if FileManager.default.fileExists(atPath: targetDir) {
            try FileManager.default.removeItem(atPath: targetDir)
        }
        try FileManager.default.moveItem(atPath: extractedPackageDir, toPath: targetDir)
    }

    private func verifyIntegrity(filePath: String, expected: String) throws {
        // Parse SRI hash: "sha512-base64hash..."
        let parts = expected.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return }

        let algorithm = String(parts[0])
        let expectedHash = String(parts[1])

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))

        let computedHash: String
        switch algorithm {
        case "sha512":
            let hash = SHA512.hash(data: data)
            computedHash = Data(hash).base64EncodedString()
        case "sha256":
            let hash = SHA256.hash(data: data)
            computedHash = Data(hash).base64EncodedString()
        case "sha1":
            let hash = Insecure.SHA1.hash(data: data)
            computedHash = Data(hash).base64EncodedString()
        default:
            return // Unknown algorithm, skip verification
        }

        guard computedHash == expectedHash else {
            throw PackageInstallerError.integrityCheckFailed(
                expected: expected,
                actual: "\(algorithm)-\(computedHash)"
            )
        }
    }
}

/// Thread-safe progress reporter for package installation
private final class InstallProgress: Sendable {
    private let counter = Mutex<Int>(0)
    private let total: Int
    private let onProgress: (@Sendable (String) -> Void)?

    init(total: Int, onProgress: (@Sendable (String) -> Void)?) {
        self.total = total
        self.onProgress = onProgress
    }

    func report(_ pkg: ResolvedPackage) {
        let count = counter.withLock { value in
            value += 1
            return value
        }
        onProgress?("installing (\(count)/\(total)) \(pkg.name)@\(pkg.version)")
    }
}

public enum PackageInstallerError: Error, CustomStringConvertible {
    case extractionFailed(String)
    case integrityCheckFailed(expected: String, actual: String)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .extractionFailed(let name):
            return "Failed to extract package '\(name)'"
        case .integrityCheckFailed(let expected, let actual):
            return "Integrity check failed: expected \(expected), got \(actual)"
        case .downloadFailed(let name):
            return "Failed to download package '\(name)'"
        }
    }
}

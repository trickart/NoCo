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
    public func install(packages: [ResolvedPackage]) async throws {
        let nodeModulesDir = (projectDir as NSString).appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(atPath: nodeModulesDir, withIntermediateDirectories: true)

        let total = packages.count
        let progress = InstallProgress(total: total, onProgress: onProgress)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            var index = 0

            while index < packages.count {
                if running >= maxConcurrency {
                    try await group.next()
                    running -= 1
                }

                let pkg = packages[index]
                let destDir = nodeModulesDir
                index += 1
                running += 1

                group.addTask {
                    try await self.installPackage(pkg, nodeModulesDir: destDir)
                    progress.report(pkg)
                }
            }

            try await group.waitForAll()
        }
    }

    private func installPackage(_ pkg: ResolvedPackage, nodeModulesDir: String) async throws {
        let targetDir: String
        if pkg.name.contains("/") {
            // Scoped package: @scope/name → node_modules/@scope/name
            let scopeDir = (nodeModulesDir as NSString).appendingPathComponent(
                (pkg.name as NSString).deletingLastPathComponent
            )
            try FileManager.default.createDirectory(atPath: scopeDir, withIntermediateDirectories: true)
            targetDir = (nodeModulesDir as NSString).appendingPathComponent(pkg.name)
        } else {
            targetDir = (nodeModulesDir as NSString).appendingPathComponent(pkg.name)
        }

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

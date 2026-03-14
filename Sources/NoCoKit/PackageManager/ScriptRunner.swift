import Foundation

/// Policy for controlling which packages may run lifecycle scripts.
public enum ScriptPolicy: Sendable {
    /// No packages may run scripts (default — safe).
    case denyAll
    /// All packages may run scripts.
    case allowAll
    /// Only the listed packages may run scripts.
    case allowList(Set<String>)
}

/// Lifecycle script information extracted from a package.json.
public struct ScriptInfo: Sendable {
    public let packageName: String
    public let version: String
    public let preinstall: String?
    public let install: String?
    public let postinstall: String?

    /// Whether there are any lifecycle scripts defined.
    public var hasScripts: Bool {
        preinstall != nil || install != nil || postinstall != nil
    }

    /// Returns a list of (phase, command) pairs in execution order.
    public var orderedScripts: [(phase: String, command: String)] {
        var result: [(String, String)] = []
        if let cmd = preinstall { result.append(("preinstall", cmd)) }
        if let cmd = install { result.append(("install", cmd)) }
        if let cmd = postinstall { result.append(("postinstall", cmd)) }
        return result
    }
}

public enum ScriptRunnerError: Error, CustomStringConvertible {
    case scriptFailed(packageName: String, phase: String, exitCode: Int32)

    public var description: String {
        switch self {
        case .scriptFailed(let name, let phase, let code):
            return "Script '\(phase)' for package '\(name)' exited with code \(code)"
        }
    }
}

/// Runs lifecycle scripts (preinstall/install/postinstall) for installed packages.
public final class ScriptRunner: Sendable {
    public let policy: ScriptPolicy
    private let onMessage: (@Sendable (String) -> Void)?

    public init(policy: ScriptPolicy, onMessage: (@Sendable (String) -> Void)? = nil) {
        self.policy = policy
        self.onMessage = onMessage
    }

    /// Check whether a package is allowed to run scripts under the current policy.
    public func isAllowed(packageName: String) -> Bool {
        switch policy {
        case .denyAll:
            return false
        case .allowAll:
            return true
        case .allowList(let allowed):
            return allowed.contains(packageName)
        }
    }

    /// Read lifecycle scripts from an installed package's package.json.
    public func readScripts(packageDir: String, name: String, version: String) -> ScriptInfo? {
        let packageJsonPath = (packageDir as NSString).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else {
            return nil
        }

        let preinstall = scripts["preinstall"]
        let install = scripts["install"]
        let postinstall = scripts["postinstall"]

        let info = ScriptInfo(
            packageName: name,
            version: version,
            preinstall: preinstall,
            install: install,
            postinstall: postinstall
        )
        return info.hasScripts ? info : nil
    }

    /// Run lifecycle scripts for a package. Executes preinstall → install → postinstall in order.
    /// Throws `ScriptRunnerError.scriptFailed` if any script exits with a non-zero code.
    public func runScripts(for info: ScriptInfo, packageDir: String) throws {
        let resolvedDir = (packageDir as NSString).resolvingSymlinksInPath

        // Build PATH with node_modules/.bin
        let nodeModulesDir = (resolvedDir as NSString).deletingLastPathComponent
        let binDir = (nodeModulesDir as NSString).appendingPathComponent(".bin")
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let newPath = "\(binDir):\(existingPath)"

        for (phase, command) in info.orderedScripts {
            onMessage?("Running \(phase) for \(info.packageName)...")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: resolvedDir)

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = newPath
            env["npm_lifecycle_event"] = phase
            env["npm_package_name"] = info.packageName
            env["npm_package_version"] = info.version
            process.environment = env

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw ScriptRunnerError.scriptFailed(
                    packageName: info.packageName,
                    phase: phase,
                    exitCode: process.terminationStatus
                )
            }
        }
    }

    /// Run scripts for all resolved packages under node_modules.
    /// Skipped packages with scripts produce warning messages.
    /// Returns the list of ScriptInfo for packages that have scripts (for --list-scripts).
    @discardableResult
    public func processPackages(_ packages: [ResolvedPackage], nodeModulesDir: String) throws -> [ScriptInfo] {
        let projectDir = (nodeModulesDir as NSString).deletingLastPathComponent
        var allScripts: [ScriptInfo] = []
        var skipped: [ScriptInfo] = []

        for pkg in packages {
            let pkgDir = (projectDir as NSString).appendingPathComponent(pkg.installPath)
            guard let info = readScripts(packageDir: pkgDir, name: pkg.name, version: pkg.version) else {
                continue
            }
            allScripts.append(info)

            if isAllowed(packageName: pkg.name) {
                try runScripts(for: info, packageDir: pkgDir)
            } else {
                skipped.append(info)
            }
        }

        if !skipped.isEmpty {
            onMessage?("\n⚠ \(skipped.count) package(s) have lifecycle scripts that were not run:")
            for info in skipped {
                let phases = info.orderedScripts.map { $0.phase }.joined(separator: ", ")
                onMessage?("  - \(info.packageName)@\(info.version) (\(phases))")
            }
            onMessage?("  Run with --allow-scripts to enable script execution.")
        }

        return allScripts
    }

    /// List scripts without executing them.
    public func listScripts(_ packages: [ResolvedPackage], nodeModulesDir: String) -> [ScriptInfo] {
        let projectDir = (nodeModulesDir as NSString).deletingLastPathComponent
        var allScripts: [ScriptInfo] = []
        for pkg in packages {
            let pkgDir = (projectDir as NSString).appendingPathComponent(pkg.installPath)
            if let info = readScripts(packageDir: pkgDir, name: pkg.name, version: pkg.version) {
                allScripts.append(info)
            }
        }
        return allScripts
    }
}

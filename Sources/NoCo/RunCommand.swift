import ArgumentParser
import Foundation
import NoCoKit

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a JavaScript file, evaluate JavaScript code, or run package.json scripts"
    )

    @Option(name: [.short, .customLong("eval")], help: "Evaluate the given JavaScript string")
    var eval: String? = nil

    @Flag(name: .customLong("license"), help: "Show license information")
    var showLicense: Bool = false

    @Argument(help: "The JavaScript file or script name to execute")
    var script: String? = nil

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the script")
    var scriptArguments: [String] = []

    func run() throws {
        if showLicense {
            print(Licenses.text)
            return
        }

        let execPath = CommandLine.arguments.first ?? "noco"
        // captureForPassthrough includes the leading "--" terminator; strip it
        let userArgs = Array(scriptArguments.drop(while: { $0 == "--" }))

        if let code = eval {
            var argv = [execPath, "[eval]"]
            argv.append(contentsOf: userArgs)
            let runtime = NodeRuntime(argv: argv)
            runtime.moduleLoader.evaluateCode(code)
            runtime.checkException()
            runtime.runEventLoop(timeout: .infinity)
        } else if let script = script {
            if isFilePath(script) {
                try runJSFile(script: script, execPath: execPath, userArgs: userArgs)
            } else {
                try runScript(name: script, args: userArgs)
            }
        } else {
            try listScripts()
        }
    }

    private func isFilePath(_ arg: String) -> Bool {
        let fileExtensions = [".js", ".mjs", ".cjs", ".ts"]
        if fileExtensions.contains(where: { arg.hasSuffix($0) }) { return true }
        if arg.contains("/") || arg.contains("\\") { return true }
        let absPath = arg.hasPrefix("/") ? arg :
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(arg)
        if FileManager.default.fileExists(atPath: absPath) { return true }
        return false
    }

    private func runJSFile(script: String, execPath: String, userArgs: [String]) throws {
        let path = (script as NSString).standardizingPath
        var absPath: String
        if path.hasPrefix("/") {
            absPath = path
        } else {
            absPath = (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(path)
        }
        // シンボリックリンクを実体パスに解決（Node.js互換）
        absPath = (absPath as NSString).resolvingSymlinksInPath

        guard FileManager.default.fileExists(atPath: absPath) else {
            throw NoCoError.fileNotFound(absPath)
        }

        var argv = [execPath, absPath]
        argv.append(contentsOf: userArgs)
        let runtime = NodeRuntime(argv: argv)
        runtime.moduleLoader.loadFile(at: absPath)
        runtime.checkException()
        runtime.runEventLoop(timeout: .infinity)
    }

    private func runScript(name: String, args: [String]) throws {
        let projectDir = FileManager.default.currentDirectoryPath
        let packageJsonPath = (projectDir as NSString).appendingPathComponent("package.json")

        guard FileManager.default.fileExists(atPath: packageJsonPath) else {
            throw PackageJsonError.fileNotFound(packageJsonPath)
        }

        let packageJson = try PackageJson.read(from: packageJsonPath)

        guard let command = packageJson.scripts[name] else {
            throw NoCoError.scriptNotFound(name, available: Array(packageJson.scripts.keys))
        }

        let nodeModulesDir = (projectDir as NSString).appendingPathComponent("node_modules")
        let binDir = (nodeModulesDir as NSString).appendingPathComponent(".bin")
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let newPath = "\(binDir):\(existingPath)"

        // pre<name> hook
        if let preCmd = packageJson.scripts["pre\(name)"] {
            try executeShell(preCmd, path: newPath, event: "pre\(name)", packageJson: packageJson)
        }

        // Main script (append extra args)
        let fullCommand = args.isEmpty ? command : "\(command) \(args.joined(separator: " "))"
        try executeShell(fullCommand, path: newPath, event: name, packageJson: packageJson)

        // post<name> hook
        if let postCmd = packageJson.scripts["post\(name)"] {
            try executeShell(postCmd, path: newPath, event: "post\(name)", packageJson: packageJson)
        }
    }

    private func executeShell(_ command: String, path: String, event: String, packageJson: PackageJson) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["npm_lifecycle_event"] = event
        env["npm_package_name"] = packageJson.name
        env["npm_package_version"] = packageJson.version
        process.environment = env

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExitCode(process.terminationStatus)
        }
    }

    private func listScripts() throws {
        let projectDir = FileManager.default.currentDirectoryPath
        let packageJsonPath = (projectDir as NSString).appendingPathComponent("package.json")

        guard FileManager.default.fileExists(atPath: packageJsonPath) else {
            throw PackageJsonError.fileNotFound(packageJsonPath)
        }

        let packageJson = try PackageJson.read(from: packageJsonPath)

        if packageJson.scripts.isEmpty {
            print("No scripts defined in package.json")
            return
        }

        print("Scripts available via `noco run`:")
        for (name, command) in packageJson.scripts.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(command)")
        }
    }
}

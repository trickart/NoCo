import ArgumentParser
import NoCoKit

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a JavaScript file or evaluate JavaScript code"
    )

    @Option(name: [.short, .customLong("eval")], help: "Evaluate the given JavaScript string")
    var eval: String? = nil

    @Flag(name: .customLong("license"), help: "Show license information")
    var showLicense: Bool = false

    @Argument(help: "The JavaScript file to execute")
    var script: String? = nil

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the script")
    var scriptArguments: [String] = []

    func validate() throws {
        if !showLicense && eval == nil && script == nil {
            throw ValidationError("Either a script file or --eval (-e) option must be provided.")
        }
    }

    func run() throws {
        if showLicense {
            print(Licenses.text)
            return
        }

        let execPath = CommandLine.arguments.first ?? "noco"
        // captureForPassthrough includes the leading "--" terminator; strip it
        let userArgs = scriptArguments.drop(while: { $0 == "--" })

        if let code = eval {
            var argv = [execPath, "[eval]"]
            argv.append(contentsOf: userArgs)
            let runtime = NodeRuntime(argv: argv)
            runtime.evaluate(code)
            runtime.runEventLoop(timeout: .infinity)
        } else if let script = script {
            let path = (script as NSString).standardizingPath
            let absPath: String
            if path.hasPrefix("/") {
                absPath = path
            } else {
                absPath = (FileManager.default.currentDirectoryPath as NSString)
                    .appendingPathComponent(path)
            }
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
    }
}

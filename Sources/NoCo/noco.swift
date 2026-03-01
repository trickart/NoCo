import ArgumentParser
import NoCoKit

@main
struct NoCo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "noco",
        abstract: "Run JavaScript files using JavaScriptCore with Node.js API compatibility"
    )

    @Argument(help: "The JavaScript file to execute")
    var script: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the script")
    var scriptArguments: [String] = []

    func run() throws {
        let runtime = NodeRuntime()

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

        runtime.moduleLoader.loadFile(at: absPath)
        runtime.runEventLoop()
    }
}

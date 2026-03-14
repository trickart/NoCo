import ArgumentParser

@main
struct NoCo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "noco",
        abstract: "Run JavaScript files using JavaScriptCore with Node.js API compatibility",
        subcommands: [RunCommand.self, InstallCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

import ArgumentParser

@main
struct NoCo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "noco",
        abstract: "Run JavaScript files using JavaScriptCore with Node.js API compatibility",
        subcommands: [RunCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

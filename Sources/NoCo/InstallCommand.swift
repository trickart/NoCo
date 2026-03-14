import ArgumentParser
import Foundation
import NoCoKit

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install npm packages",
        aliases: ["i", "add"]
    )

    @Argument(help: "Packages to install (e.g. lodash, express@4.18.0)")
    var packages: [String] = []

    @Flag(name: [.customLong("save-dev"), .customShort("D")],
          help: "Save to devDependencies")
    var saveDev: Bool = false

    @Flag(name: .customLong("production"),
          help: "Skip devDependencies")
    var production: Bool = false

    @Option(name: .customLong("allow-scripts"),
            help: "Allow lifecycle scripts: 'all' or comma-separated package names")
    var allowScripts: String?

    @Flag(name: .customLong("ignore-scripts"),
          help: "Explicitly disable lifecycle scripts (default behavior)")
    var ignoreScripts: Bool = false

    @Flag(name: .customLong("list-scripts"),
          help: "List lifecycle scripts without executing them")
    var listScripts: Bool = false

    func run() async throws {
        let projectDir = FileManager.default.currentDirectoryPath
        let packageJsonPath = (projectDir as NSString).appendingPathComponent("package.json")
        let lockfilePath = (projectDir as NSString).appendingPathComponent("package-lock.json")

        let startTime = CFAbsoluteTimeGetCurrent()

        // Read or create package.json
        var packageJson: PackageJson
        if FileManager.default.fileExists(atPath: packageJsonPath) {
            packageJson = try PackageJson.read(from: packageJsonPath)
        } else if packages.isEmpty {
            print("No package.json found and no packages specified.")
            throw ExitCode.failure
        } else {
            packageJson = PackageJson(
                name: (projectDir as NSString).lastPathComponent,
                version: "1.0.0"
            )
        }

        // Read existing lockfile if present
        var lockfile: Lockfile?
        if FileManager.default.fileExists(atPath: lockfilePath) {
            lockfile = try? Lockfile.read(from: lockfilePath)
        }

        // Determine dependencies to resolve
        var depsToResolve: [String: String]

        if packages.isEmpty {
            // Install from package.json
            depsToResolve = packageJson.dependencies
            if !production {
                depsToResolve.merge(packageJson.devDependencies) { current, _ in current }
            }
        } else {
            // Install specified packages
            depsToResolve = [:]
            for spec in packages {
                let (name, version) = parsePackageSpec(spec)
                depsToResolve[name] = version
            }
        }

        if depsToResolve.isEmpty {
            print("No dependencies to install.")
            return
        }

        // Resolve dependencies
        let registry = NpmRegistry()
        let resolver = DependencyResolver(registry: registry, lockfile: lockfile)

        print("Resolving dependencies...")
        let resolvedPackages = try await resolver.resolve(dependencies: depsToResolve)

        if resolvedPackages.isEmpty {
            print("All packages are up to date.")
            return
        }

        // Determine script policy
        let scriptPolicy: ScriptPolicy
        if ignoreScripts {
            scriptPolicy = .denyAll
        } else if let allowValue = allowScripts {
            if allowValue == "all" {
                scriptPolicy = .allowAll
            } else {
                let names = Set(allowValue.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
                scriptPolicy = .allowList(names)
            }
        } else {
            scriptPolicy = .denyAll
        }

        let scriptRunner = ScriptRunner(policy: scriptPolicy) { message in
            print(message)
        }

        // Install packages
        let installer = PackageInstaller(registry: registry, projectDir: projectDir) { message in
            print("\r\u{1B}[K\(message)", terminator: "")
            fflush(stdout)
        }

        try await installer.install(packages: resolvedPackages, scriptRunner: listScripts ? nil : scriptRunner)
        print("") // newline after progress

        // List scripts mode
        if listScripts {
            let nodeModulesDir = (projectDir as NSString).appendingPathComponent("node_modules")
            let scripts = scriptRunner.listScripts(resolvedPackages, nodeModulesDir: nodeModulesDir)
            if scripts.isEmpty {
                print("No lifecycle scripts found.")
            } else {
                print("Lifecycle scripts:")
                for info in scripts {
                    print("  \(info.packageName)@\(info.version):")
                    for (phase, command) in info.orderedScripts {
                        print("    \(phase): \(command)")
                    }
                }
            }
        }

        // Update package.json if packages were specified on command line
        if !packages.isEmpty {
            for spec in packages {
                let (name, _) = parsePackageSpec(spec)
                // Find the resolved version to write a proper range
                if let resolved = resolvedPackages.first(where: { $0.name == name }) {
                    let versionRange = "^\(resolved.version)"
                    packageJson.addDependency(name: name, version: versionRange, dev: saveDev)
                }
            }
            try packageJson.write(to: packageJsonPath)
        }

        // Write lockfile
        var newLockfile = Lockfile(name: packageJson.name, version: packageJson.version)
        newLockfile.setRoot(
            name: packageJson.name,
            version: packageJson.version,
            dependencies: packageJson.dependencies,
            devDependencies: packageJson.devDependencies
        )
        for pkg in resolvedPackages {
            newLockfile.addPackage(pkg)
        }
        try newLockfile.write(to: lockfilePath)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let elapsedStr = String(format: "%.1f", elapsed)
        print("added \(resolvedPackages.count) packages in \(elapsedStr)s")
    }

    /// Parse "lodash", "express@4.18.0", "@scope/pkg@^1.0.0"
    private func parsePackageSpec(_ spec: String) -> (name: String, version: String) {
        // Handle scoped packages: @scope/name@version
        if spec.hasPrefix("@") {
            // Find the second @ (version separator)
            if let slashIndex = spec.firstIndex(of: "/") {
                let afterSlash = spec[spec.index(after: slashIndex)...]
                if let atIndex = afterSlash.firstIndex(of: "@") {
                    let name = String(spec[spec.startIndex..<atIndex])
                    let version = String(spec[spec.index(after: atIndex)...])
                    return (name, version)
                }
            }
            return (spec, "*")
        }

        // Regular package: name@version
        if let atIndex = spec.firstIndex(of: "@") {
            let name = String(spec[spec.startIndex..<atIndex])
            let version = String(spec[spec.index(after: atIndex)...])
            return (name, version)
        }

        return (spec, "*")
    }
}

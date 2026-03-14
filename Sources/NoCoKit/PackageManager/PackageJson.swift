import Foundation

/// Reads and writes package.json files.
public struct PackageJson: Sendable {
    public var name: String
    public var version: String
    public var dependencies: [String: String]
    public var devDependencies: [String: String]
    public var optionalDependencies: [String: String]
    public var scripts: [String: String]
    /// Raw JSON bytes for round-trip preservation of unknown fields
    private var rawJSON: Data?

    public init(name: String = "", version: String = "1.0.0",
                dependencies: [String: String] = [:],
                devDependencies: [String: String] = [:],
                optionalDependencies: [String: String] = [:],
                scripts: [String: String] = [:]) {
        self.name = name
        self.version = version
        self.dependencies = dependencies
        self.devDependencies = devDependencies
        self.optionalDependencies = optionalDependencies
        self.scripts = scripts
        self.rawJSON = nil
    }

    /// Read a package.json from a file path
    public static func read(from path: String) throws -> PackageJson {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(data)
    }

    /// Parse package.json data
    public static func parse(_ data: Data) throws -> PackageJson {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageJsonError.invalidFormat
        }
        var pkg = PackageJson()
        pkg.rawJSON = data
        pkg.name = json["name"] as? String ?? ""
        pkg.version = json["version"] as? String ?? "1.0.0"
        pkg.dependencies = json["dependencies"] as? [String: String] ?? [:]
        pkg.devDependencies = json["devDependencies"] as? [String: String] ?? [:]
        pkg.optionalDependencies = json["optionalDependencies"] as? [String: String] ?? [:]
        pkg.scripts = json["scripts"] as? [String: String] ?? [:]
        return pkg
    }

    /// Add a dependency to this package.json
    public mutating func addDependency(name: String, version: String, dev: Bool = false) {
        if dev {
            devDependencies[name] = version
        } else {
            dependencies[name] = version
        }
    }

    /// Write package.json to a file path, preserving existing field order
    public func write(to path: String) throws {
        // Reconstruct base from raw JSON if available, then overlay typed fields
        var output: [String: Any]
        if let rawJSON,
           let base = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] {
            output = base
        } else {
            output = [:]
        }

        output["name"] = name
        output["version"] = version

        if !dependencies.isEmpty {
            output["dependencies"] = dependencies
        } else {
            output.removeValue(forKey: "dependencies")
        }

        if !devDependencies.isEmpty {
            output["devDependencies"] = devDependencies
        } else {
            output.removeValue(forKey: "devDependencies")
        }

        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var str = String(data: data, encoding: .utf8)! + "\n"
        str = str.replacingOccurrences(of: "    ", with: "  ")
        try str.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

public enum PackageJsonError: Error, CustomStringConvertible {
    case invalidFormat
    case fileNotFound(String)

    public var description: String {
        switch self {
        case .invalidFormat: return "Invalid package.json format"
        case .fileNotFound(let path): return "package.json not found at \(path)"
        }
    }
}

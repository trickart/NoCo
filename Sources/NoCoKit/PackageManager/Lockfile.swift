import Foundation

/// Info for a single package entry in the lockfile.
public struct LockfilePackageInfo: Sendable {
    public var version: String
    public var resolved: String
    public var integrity: String
    public var dependencies: [String: String]
    /// Root-only fields
    public var name: String?
    public var devDependencies: [String: String]?

    public init(version: String = "", resolved: String = "", integrity: String = "",
                dependencies: [String: String] = [:],
                name: String? = nil, devDependencies: [String: String]? = nil) {
        self.version = version
        self.resolved = resolved
        self.integrity = integrity
        self.dependencies = dependencies
        self.name = name
        self.devDependencies = devDependencies
    }
}

/// Reads and writes package-lock.json files (lockfileVersion 3, npm v7+ compatible).
public struct Lockfile: Sendable {
    public var name: String
    public var version: String
    public let lockfileVersion: Int = 3
    /// Map of package paths to their info.
    /// Key "" is the root project, "node_modules/foo" is a dependency.
    public var packages: [String: LockfilePackageInfo]

    public init(name: String = "", version: String = "1.0.0") {
        self.name = name
        self.version = version
        self.packages = [:]
    }

    /// Read a package-lock.json from a file path
    public static func read(from path: String) throws -> Lockfile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(data)
    }

    /// Parse package-lock.json data
    public static func parse(_ data: Data) throws -> Lockfile {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LockfileError.invalidFormat
        }

        var lockfile = Lockfile()
        lockfile.name = json["name"] as? String ?? ""
        lockfile.version = json["version"] as? String ?? "1.0.0"

        if let packages = json["packages"] as? [String: Any] {
            for (key, value) in packages {
                guard let pkgDict = value as? [String: Any] else { continue }
                let info = LockfilePackageInfo(
                    version: pkgDict["version"] as? String ?? "",
                    resolved: pkgDict["resolved"] as? String ?? "",
                    integrity: pkgDict["integrity"] as? String ?? "",
                    dependencies: pkgDict["dependencies"] as? [String: String] ?? [:],
                    name: pkgDict["name"] as? String,
                    devDependencies: pkgDict["devDependencies"] as? [String: String]
                )
                lockfile.packages[key] = info
            }
        }

        return lockfile
    }

    /// Add a resolved package entry to the lockfile
    public mutating func addPackage(_ pkg: ResolvedPackage) {
        let key = pkg.installPath
        packages[key] = LockfilePackageInfo(
            version: pkg.version,
            resolved: pkg.tarballURL,
            integrity: pkg.integrity,
            dependencies: pkg.dependencies
        )
    }

    /// Set root project info
    public mutating func setRoot(name: String, version: String, dependencies: [String: String], devDependencies: [String: String] = [:]) {
        self.name = name
        self.version = version
        packages[""] = LockfilePackageInfo(
            version: version,
            dependencies: dependencies,
            name: name,
            devDependencies: devDependencies.isEmpty ? nil : devDependencies
        )
    }

    /// Write the lockfile to disk
    public func write(to path: String) throws {
        var packagesDict: [String: Any] = [:]
        for (key, info) in packages {
            var entry: [String: Any] = [
                "version": info.version
            ]
            if !info.resolved.isEmpty { entry["resolved"] = info.resolved }
            if !info.integrity.isEmpty { entry["integrity"] = info.integrity }
            if !info.dependencies.isEmpty { entry["dependencies"] = info.dependencies }
            if let name = info.name { entry["name"] = name }
            if let devDeps = info.devDependencies, !devDeps.isEmpty {
                entry["devDependencies"] = devDeps
            }
            packagesDict[key] = entry
        }

        let output: [String: Any] = [
            "name": name,
            "version": version,
            "lockfileVersion": lockfileVersion,
            "requires": true,
            "packages": packagesDict
        ]

        let data = try JSONSerialization.data(
            withJSONObject: output,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var str = String(data: data, encoding: .utf8)! + "\n"
        str = str.replacingOccurrences(of: "    ", with: "  ")
        try str.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

public enum LockfileError: Error, CustomStringConvertible {
    case invalidFormat

    public var description: String {
        switch self {
        case .invalidFormat: return "Invalid package-lock.json format"
        }
    }
}

import Foundation
import Synchronization

/// Client for the npm registry API.
public final class NpmRegistry: Sendable {
    private let registryURL: String
    private let session: URLSession
    private let metadataCache = Mutex<[String: NpmPackageMetadata]>([:])

    public init(registryURL: String = "https://registry.npmjs.org") {
        self.registryURL = registryURL
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Accept": "application/json"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch package metadata from the registry
    public func fetchMetadata(for package: String) async throws -> NpmPackageMetadata {
        if let cached = metadataCache.withLock({ $0[package] }) {
            return cached
        }

        let encodedName = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? package
        let url = URL(string: "\(registryURL)/\(encodedName)")!

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NpmRegistryError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw NpmRegistryError.packageNotFound(package)
            }
            throw NpmRegistryError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NpmRegistryError.invalidResponse
        }

        let metadata = try NpmPackageMetadata.parse(json, name: package)

        metadataCache.withLock { $0[package] = metadata }

        return metadata
    }

    /// Download a tarball to a temporary file, returning the file path
    public func downloadTarball(url: String, to destination: String) async throws {
        guard let tarballURL = URL(string: url) else {
            throw NpmRegistryError.networkError("Invalid tarball URL: \(url)")
        }
        let (tempURL, _) = try await session.download(from: tarballURL)
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destination))
    }
}

// MARK: - Data Models

public struct NpmPackageMetadata: Sendable {
    public let name: String
    public let distTags: [String: String]
    public let versions: [String: NpmVersionInfo]

    /// Get the latest version string
    public var latestVersion: String? {
        distTags["latest"]
    }

    static func parse(_ json: [String: Any], name: String) throws -> NpmPackageMetadata {
        let distTags = json["dist-tags"] as? [String: String] ?? [:]
        let versionsJson = json["versions"] as? [String: Any] ?? [:]

        var versions: [String: NpmVersionInfo] = [:]
        for (versionStr, vInfo) in versionsJson {
            guard let vDict = vInfo as? [String: Any] else { continue }
            versions[versionStr] = NpmVersionInfo.parse(vDict)
        }

        return NpmPackageMetadata(name: name, distTags: distTags, versions: versions)
    }
}

public struct PeerDepMeta: Sendable {
    public let optional: Bool

    public init(optional: Bool = false) {
        self.optional = optional
    }
}

public struct NpmVersionInfo: Sendable {
    public let version: String
    public let dependencies: [String: String]
    public let devDependencies: [String: String]
    public let peerDependencies: [String: String]
    public let peerDependenciesMeta: [String: PeerDepMeta]
    public let dist: NpmDist
    public let bin: [String: String]?

    static func parse(_ json: [String: Any]) -> NpmVersionInfo {
        let version = json["version"] as? String ?? ""
        let deps = json["dependencies"] as? [String: String] ?? [:]
        let devDeps = json["devDependencies"] as? [String: String] ?? [:]
        let peerDeps = json["peerDependencies"] as? [String: String] ?? [:]

        var peerMeta: [String: PeerDepMeta] = [:]
        if let metaJson = json["peerDependenciesMeta"] as? [String: Any] {
            for (key, value) in metaJson {
                if let dict = value as? [String: Any] {
                    let optional = dict["optional"] as? Bool ?? false
                    peerMeta[key] = PeerDepMeta(optional: optional)
                }
            }
        }

        let distJson = json["dist"] as? [String: Any] ?? [:]
        let dist = NpmDist(
            tarball: distJson["tarball"] as? String ?? "",
            shasum: distJson["shasum"] as? String ?? "",
            integrity: distJson["integrity"] as? String ?? ""
        )

        var bin: [String: String]?
        if let binField = json["bin"] as? [String: String] {
            bin = binField
        } else if let binField = json["bin"] as? String {
            let name = json["name"] as? String ?? ""
            bin = [name: binField]
        }

        return NpmVersionInfo(version: version, dependencies: deps,
                              devDependencies: devDeps,
                              peerDependencies: peerDeps,
                              peerDependenciesMeta: peerMeta,
                              dist: dist, bin: bin)
    }
}

public struct NpmDist: Sendable {
    public let tarball: String
    public let shasum: String
    public let integrity: String
}

// MARK: - Errors

public enum NpmRegistryError: Error, CustomStringConvertible {
    case packageNotFound(String)
    case httpError(Int)
    case invalidResponse
    case networkError(String)

    public var description: String {
        switch self {
        case .packageNotFound(let name): return "Package '\(name)' not found in registry"
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidResponse: return "Invalid response from registry"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

import Foundation

/// Detects whether a file should be treated as ESM or CJS.
///
/// Rules:
/// - `.mjs` → ESM
/// - `.cjs` → CJS
/// - `.js` + nearest `package.json` `"type": "module"` → ESM
/// - `.js` + `"type": "commonjs"` or unspecified → CJS
public final class ESMDetector: @unchecked Sendable {
    /// Shared instance.
    public static let shared = ESMDetector()

    /// Cache of directory → package.json "type" field value.
    private var packageTypeCache: [String: String?] = [:]

    private init() {}

    /// Returns `true` if the file at `path` should be treated as an ES module.
    public func isESM(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mjs":
            return true
        case "cjs":
            return false
        case "js":
            let pkgType = findNearestPackageType(from: (path as NSString).deletingLastPathComponent)
            return pkgType == "module"
        default:
            return false
        }
    }

    /// Walk up directories from `dir` to find the nearest package.json with a "type" field.
    public func findNearestPackageType(from dir: String) -> String? {
        var current = (dir as NSString).standardizingPath
        let fm = FileManager.default

        while true {
            if let cached = packageTypeCache[current] {
                return cached
            }

            let pkgPath = (current as NSString).appendingPathComponent("package.json")
            if fm.fileExists(atPath: pkgPath),
               let data = fm.contents(atPath: pkgPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let type = json["type"] as? String {
                    packageTypeCache[current] = type
                    return type
                }
                // package.json exists but no "type" field → CJS (stop searching)
                packageTypeCache[current] = nil
                return nil
            }

            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }

        return nil
    }

    /// Clear the package type cache (useful for testing).
    public func clearCache() {
        packageTypeCache.removeAll()
    }
}

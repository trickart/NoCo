import Foundation

/// Semantic versioning parser, comparator, and range matcher.
public struct SemVer: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            s += "-" + prerelease.joined(separator: ".")
        }
        return s
    }

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parse a semver string like "1.2.3", "1.2.3-beta.1"
    public init?(_ string: String) {
        var s = string
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s = String(s.dropFirst())
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // Split off prerelease
        let prereleaseComponents: [String]
        let versionPart: String
        if let hyphenIndex = s.firstIndex(of: "-") {
            versionPart = String(s[s.startIndex..<hyphenIndex])
            let preStr = String(s[s.index(after: hyphenIndex)...])
            // Strip build metadata (+...)
            if let plusIndex = preStr.firstIndex(of: "+") {
                prereleaseComponents = String(preStr[preStr.startIndex..<plusIndex]).split(separator: ".").map(String.init)
            } else {
                prereleaseComponents = preStr.split(separator: ".").map(String.init)
            }
        } else if let plusIndex = s.firstIndex(of: "+") {
            versionPart = String(s[s.startIndex..<plusIndex])
            prereleaseComponents = []
        } else {
            versionPart = s
            prereleaseComponents = []
        }

        let parts = versionPart.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prereleaseComponents
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // No prerelease > prerelease (1.0.0 > 1.0.0-alpha)
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return false }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return true }

        // Compare prerelease identifiers
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            if let li = Int(l), let ri = Int(r) {
                return li < ri
            }
            if Int(l) != nil { return true }   // numeric < string
            if Int(r) != nil { return false }
            return l < r
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - SemVerRange

/// Represents an npm-style semver range (e.g. "^1.2.3", ">=1.0.0 <2.0.0", "1.x")
public struct SemVerRange: Sendable {
    private let comparatorSets: [[Comparator]]

    /// A single comparator like ">=1.2.3" or "<2.0.0"
    struct Comparator: Sendable {
        enum Op: Sendable { case eq, gt, gte, lt, lte }
        let op: Op
        let version: SemVer
    }

    public init?(_ range: String) {
        let trimmed = range.trimmingCharacters(in: .whitespaces)

        // Handle empty or "*"
        if trimmed.isEmpty || trimmed == "*" || trimmed == "latest" {
            self.comparatorSets = [[]]
            return
        }

        // Split on ||
        let orParts = trimmed.components(separatedBy: "||")
        var sets: [[Comparator]] = []

        for orPart in orParts {
            let part = orPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }

            if let comps = SemVerRange.parseComparatorSet(part) {
                sets.append(comps)
            } else {
                return nil
            }
        }

        if sets.isEmpty { return nil }
        self.comparatorSets = sets
    }

    /// Check if a version satisfies this range
    public func satisfiedBy(_ version: SemVer) -> Bool {
        for set in comparatorSets {
            if set.isEmpty {
                // "*" matches everything (except prereleases on different tuples)
                return true
            }
            var satisfied = true
            for comp in set {
                if !SemVerRange.matches(version, comp) {
                    satisfied = false
                    break
                }
            }
            if satisfied { return true }
        }
        return false
    }

    /// Find the best (highest) matching version from a list
    public func bestMatch(from versions: [SemVer]) -> SemVer? {
        versions
            .filter { satisfiedBy($0) }
            .sorted()
            .last
    }

    // MARK: - Parsing

    private static func parseComparatorSet(_ input: String) -> [Comparator]? {
        let s = input.trimmingCharacters(in: .whitespaces)

        // Hyphen range: "1.2.3 - 2.3.4"
        let hyphenParts = s.components(separatedBy: " - ")
        if hyphenParts.count == 2 {
            return parseHyphenRange(hyphenParts[0].trimmingCharacters(in: .whitespaces),
                                   hyphenParts[1].trimmingCharacters(in: .whitespaces))
        }

        // Caret: ^1.2.3
        if s.hasPrefix("^") {
            return parseCaret(String(s.dropFirst()))
        }

        // Tilde: ~1.2.3
        if s.hasPrefix("~") {
            return parseTilde(String(s.dropFirst()))
        }

        // x-range: 1.x, 1.2.x, 1.*, 1.2.*
        if s.contains("x") || s.contains("X") || s.contains("*") || !s.contains(".") || s.split(separator: ".").count < 3 {
            if let xResult = parseXRange(s) {
                return xResult
            }
        }

        // Space-separated comparators: >=1.0.0 <2.0.0
        let tokens = s.split(separator: " ").map(String.init)
        var comps: [Comparator] = []
        for token in tokens {
            if let c = parseSingleComparator(token) {
                comps.append(c)
            } else {
                return nil
            }
        }
        return comps.isEmpty ? nil : comps
    }

    private static func parseSingleComparator(_ s: String) -> Comparator? {
        var str = s.trimmingCharacters(in: .whitespaces)
        let op: Comparator.Op

        if str.hasPrefix(">=") {
            op = .gte
            str = String(str.dropFirst(2))
        } else if str.hasPrefix("<=") {
            op = .lte
            str = String(str.dropFirst(2))
        } else if str.hasPrefix(">") {
            op = .gt
            str = String(str.dropFirst(1))
        } else if str.hasPrefix("<") {
            op = .lt
            str = String(str.dropFirst(1))
        } else if str.hasPrefix("=") {
            op = .eq
            str = String(str.dropFirst(1))
        } else {
            op = .eq
        }

        guard let version = SemVer(str) else { return nil }
        return Comparator(op: op, version: version)
    }

    private static func parseCaret(_ s: String) -> [Comparator]? {
        let parts = s.split(separator: ".").map(String.init)
        guard let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2].split(separator: "-")[0]) ?? 0 : 0

        let lower = SemVer(major: major, minor: minor, patch: patch)

        let upper: SemVer
        if major != 0 {
            upper = SemVer(major: major + 1, minor: 0, patch: 0)
        } else if minor != 0 {
            upper = SemVer(major: 0, minor: minor + 1, patch: 0)
        } else {
            upper = SemVer(major: 0, minor: 0, patch: patch + 1)
        }

        return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: upper)]
    }

    private static func parseTilde(_ s: String) -> [Comparator]? {
        let parts = s.split(separator: ".").map(String.init)
        guard let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2].split(separator: "-")[0]) ?? 0 : 0

        let lower = SemVer(major: major, minor: minor, patch: patch)
        let upper = SemVer(major: major, minor: minor + 1, patch: 0)

        return [Comparator(op: .gte, version: lower), Comparator(op: .lt, version: upper)]
    }

    private static func parseXRange(_ s: String) -> [Comparator]? {
        let normalized = s.replacingOccurrences(of: "X", with: "x")
                          .replacingOccurrences(of: "*", with: "x")
        let parts = normalized.split(separator: ".").map(String.init)

        guard let first = parts.first, let major = Int(first) else {
            if parts.first == "x" { return [] } // "*" → match all
            // Try as exact version (no dots, single number like "1")
            if let major = Int(s) {
                return [
                    Comparator(op: .gte, version: SemVer(major: major, minor: 0, patch: 0)),
                    Comparator(op: .lt, version: SemVer(major: major + 1, minor: 0, patch: 0))
                ]
            }
            return nil
        }

        if parts.count == 1 || (parts.count > 1 && parts[1] == "x") {
            return [
                Comparator(op: .gte, version: SemVer(major: major, minor: 0, patch: 0)),
                Comparator(op: .lt, version: SemVer(major: major + 1, minor: 0, patch: 0))
            ]
        }

        if parts.count > 1, let minor = Int(parts[1]) {
            if parts.count == 2 || (parts.count > 2 && parts[2] == "x") {
                return [
                    Comparator(op: .gte, version: SemVer(major: major, minor: minor, patch: 0)),
                    Comparator(op: .lt, version: SemVer(major: major, minor: minor + 1, patch: 0))
                ]
            }
        }

        // Not an x-range, try as exact version
        if let v = SemVer(s) {
            return [Comparator(op: .eq, version: v)]
        }
        return nil
    }

    private static func parseHyphenRange(_ low: String, _ high: String) -> [Comparator]? {
        guard let lower = SemVer(low), let upper = SemVer(high) else { return nil }
        return [
            Comparator(op: .gte, version: lower),
            Comparator(op: .lte, version: upper)
        ]
    }

    private static func matches(_ version: SemVer, _ comp: Comparator) -> Bool {
        switch comp.op {
        case .eq:  return version == comp.version
        case .gt:  return version > comp.version
        case .gte: return version >= comp.version
        case .lt:  return version < comp.version
        case .lte: return version <= comp.version
        }
    }
}

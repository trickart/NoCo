import Foundation

/// Transforms ESM import/export syntax into ESM runtime calls.
/// Uses regex-based parsing with comment/string exclusion.
public enum ESMTransformer {

    // MARK: - Public API

    /// Transform ESM source (import/export) into ESM runtime calls.
    /// Used for files detected as ESM.
    public static func transform(_ source: String) -> String {
        var result = source

        // 1. Transform imports
        result = transformImports(result, excluded: buildExcludedRanges(in: result))

        // 2. Transform exports (re-build excluded ranges after import transforms)
        result = transformExports(result, excluded: buildExcludedRanges(in: result))

        // 3. Add import.meta support
        result = transformImportMeta(result, excluded: buildExcludedRanges(in: result))

        // 4. Transform dynamic import() — applies to all files
        result = transformDynamicImportInSource(result, excluded: buildExcludedRanges(in: result))

        // 5. Prepend import_meta definition and __esModule marker (single line to preserve line numbers)
        let header = "Object.defineProperty(module.exports, '__esModule', {value: true}); var import_meta = Object.freeze({ url: 'file://' + __filename, dirname: __dirname, filename: __filename });"
        result = header + result

        return result
    }

    /// Transform only dynamic `import()` expressions. Used for CJS files.
    public static func transformDynamicImport(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        return transformDynamicImportInSource(source, excluded: excluded)
    }

    // MARK: - Excluded Ranges (comments & strings)

    private struct ExcludedRange {
        let start: Int
        let end: Int

        func contains(_ index: Int) -> Bool {
            return index >= start && index < end
        }
    }

    /// Build list of ranges that are inside comments or string literals.
    private static func buildExcludedRanges(in source: String) -> [ExcludedRange] {
        var ranges: [ExcludedRange] = []
        let chars = Array(source.utf16)
        let len = chars.count
        var i = 0

        while i < len {
            let ch = chars[i]

            // Single-line comment
            if ch == 0x2F && i + 1 < len && chars[i + 1] == 0x2F {
                let start = i
                i += 2
                while i < len && chars[i] != 0x0A { i += 1 }
                ranges.append(ExcludedRange(start: start, end: i))
                continue
            }

            // Multi-line comment
            if ch == 0x2F && i + 1 < len && chars[i + 1] == 0x2A {
                let start = i
                i += 2
                while i + 1 < len {
                    if chars[i] == 0x2A && chars[i + 1] == 0x2F {
                        i += 2
                        break
                    }
                    i += 1
                }
                ranges.append(ExcludedRange(start: start, end: i))
                continue
            }

            // String literals
            if ch == 0x27 || ch == 0x22 || ch == 0x60 {
                let quote = ch
                let start = i
                i += 1
                while i < len {
                    if chars[i] == 0x5C { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    i += 1
                }
                ranges.append(ExcludedRange(start: start, end: i))
                continue
            }

            // Regex literal (heuristic)
            if ch == 0x2F {
                let prevNonSpace = findPrevNonSpace(chars, before: i)
                let isRegex: Bool
                if prevNonSpace < 0 {
                    isRegex = true
                } else {
                    let prev = chars[prevNonSpace]
                    isRegex = [0x3D, 0x28, 0x5B, 0x21, 0x26, 0x7C, 0x3F, 0x3A, 0x2C, 0x3B, 0x7B, 0x7D, 0x0A, 0x0D].contains(prev)
                }
                if isRegex {
                    let start = i
                    i += 1
                    while i < len {
                        if chars[i] == 0x5C { i += 2; continue }
                        if chars[i] == 0x2F {
                            i += 1
                            while i < len && isIdentChar(chars[i]) { i += 1 }
                            break
                        }
                        if chars[i] == 0x0A { break }
                        i += 1
                    }
                    ranges.append(ExcludedRange(start: start, end: i))
                    continue
                }
            }

            i += 1
        }

        return ranges
    }

    private static func findPrevNonSpace(_ chars: [UInt16], before index: Int) -> Int {
        var i = index - 1
        while i >= 0 {
            let ch = chars[i]
            if ch != 0x20 && ch != 0x09 && ch != 0x0D { return i }
            i -= 1
        }
        return -1
    }

    private static func isIdentChar(_ ch: UInt16) -> Bool {
        return (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x41 && ch <= 0x5A)
            || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F || ch == 0x24
    }

    private static func isInExcluded(_ offset: Int, _ ranges: [ExcludedRange]) -> Bool {
        for r in ranges {
            if r.contains(offset) { return true }
            if r.start > offset { break }
        }
        return false
    }

    // MARK: - Import Transformation

    private static func transformImports(_ source: String, excluded: [ExcludedRange]) -> String {
        var result = source

        let patterns: [(NSRegularExpression, (String, NSTextCheckingResult) -> String?)] = [
            // import x, { a, b } from 'y'  (default + named)
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*import\s+(\w+)\s*,\s*\{([^}]*)\}\s*from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let defaultName = substr(src, match.range(at: 1))
                 let named = substr(src, match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                 let specifier = substr(src, match.range(at: 3))
                 let destructured = transformNamedImports(named)
                 return "var __m = __esm_import('\(specifier)', __dirname); var \(defaultName) = __m.default; var { \(destructured) } = __m;"
             }),
            // import * as ns from 'y'
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*import\s+\*\s+as\s+(\w+)\s+from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let ns = substr(src, match.range(at: 1))
                 let specifier = substr(src, match.range(at: 2))
                 return "var \(ns) = __esm_import('\(specifier)', __dirname);"
             }),
            // import { a, b } from 'y'
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*import\s+\{([^}]*)\}\s*from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let named = substr(src, match.range(at: 1))
                 let specifier = substr(src, match.range(at: 2))
                 let destructured = transformNamedImports(named)
                 return "var { \(destructured) } = __esm_import('\(specifier)', __dirname);"
             }),
            // import x from 'y'
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*import\s+(\w+)\s+from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let name = substr(src, match.range(at: 1))
                 let specifier = substr(src, match.range(at: 2))
                 return "var __m = __esm_import('\(specifier)', __dirname); var \(name) = __m.default;"
             }),
            // import 'y'  (side-effect only)
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*import\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let specifier = substr(src, match.range(at: 1))
                 return "__esm_import('\(specifier)', __dirname);"
             }),
        ]

        for (regex, transformer) in patterns {
            result = applyRegex(regex, to: result, excluded: excluded, transformer: transformer)
        }

        return result
    }

    private static func transformNamedImports(_ named: String) -> String {
        let parts = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.map { part in
            let tokens = part.split(separator: " ").map(String.init)
            if tokens.count == 3 && tokens[1] == "as" {
                return "\(tokens[0]): \(tokens[2])"
            }
            return part
        }.joined(separator: ", ")
    }

    // MARK: - Export Transformation

    private static func transformExports(_ source: String, excluded: [ExcludedRange]) -> String {
        var result = source

        let patterns: [(NSRegularExpression, (String, NSTextCheckingResult) -> String?)] = [
            // export default function name(...) {
            // → __esm_export_default(module, name);\nfunction name(...) {
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+default\s+((?:async\s+)?function\s*\*?\s*(\w+)\s*\([^)]*\)\s*\{)"#),
             { src, match in
                 let funcDecl = substr(src, match.range(at: 1))
                 let name = substr(src, match.range(at: 2))
                 // Function is hoisted, so export call before declaration works
                 return "__esm_export_default(module, \(name));\n\(funcDecl)"
             }),

            // export default class Name {
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+default\s+(class\s+(\w+)\s*(?:extends\s+[^{]+)?\{)"#),
             { src, match in
                 let classDecl = substr(src, match.range(at: 1))
                 let name = substr(src, match.range(at: 2))
                 // Use getter for class since classes are NOT hoisted
                 return "__esm_export(module, 'default', function() { return \(name); });\n\(classDecl)"
             }),

            // export default expr (must come after function/class)
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+default\s+(?!function\b|class\b)(.+)"#),
             { src, match in
                 var expr = substr(src, match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                 if expr.hasSuffix(";") { expr = String(expr.dropLast()) }
                 return "__esm_export_default(module, \(expr));"
             }),

            // export { a, b } from 'y'  (re-export named)
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+\{([^}]*)\}\s*from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let named = substr(src, match.range(at: 1))
                 let specifier = substr(src, match.range(at: 2))
                 let parts = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                 // Use IIFE to scope the re-export variable
                 var exportLines: [String] = []
                 for part in parts {
                     let tokens = part.split(separator: " ").map(String.init)
                     if tokens.count == 3 && tokens[1] == "as" {
                         exportLines.append("__esm_export(module, '\(tokens[2])', function() { return __re.\(tokens[0]); });")
                     } else if tokens.count == 1 {
                         exportLines.append("__esm_export(module, '\(tokens[0])', function() { return __re.\(tokens[0]); });")
                     }
                 }
                 return "(function() { var __re = __esm_import('\(specifier)', __dirname); \(exportLines.joined(separator: " ")) })();"
             }),

            // export * from 'y'
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+\*\s+from\s+['"]([^'"]+)['"]"#),
             { src, match in
                 let specifier = substr(src, match.range(at: 1))
                 return "__esm_export_star(module, __esm_import('\(specifier)', __dirname));"
             }),

            // export function name(...) {
            // → __esm_export(module, 'name', ...);\nfunction name(...) {
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+((?:async\s+)?function\s*\*?\s*(\w+)\s*\([^)]*\)\s*\{)"#),
             { src, match in
                 let funcDecl = substr(src, match.range(at: 1))
                 let name = substr(src, match.range(at: 2))
                 return "__esm_export(module, '\(name)', function() { return \(name); });\n\(funcDecl)"
             }),

            // export class Name {
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+(class\s+(\w+)\s*(?:extends\s+[^{]+)?\{)"#),
             { src, match in
                 let classDecl = substr(src, match.range(at: 1))
                 let name = substr(src, match.range(at: 2))
                 return "__esm_export(module, '\(name)', function() { return \(name); });\n\(classDecl)"
             }),

            // export const/let/var
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+((?:const|let|var)\s+.+)"#),
             { src, match in
                 let decl = substr(src, match.range(at: 1))
                 let names = extractDeclaredNames(from: decl)
                 let exports = names.map { "__esm_export(module, '\($0)', function() { return \($0); });" }
                 return "\(decl)\n\(exports.joined(separator: "\n"))"
             }),

            // export { a, b }  (local re-export, no 'from')
            (try! NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+\{([^}]*)\}\s*(?:;|\n|$)"#),
             { src, match in
                 let named = substr(src, match.range(at: 1))
                 let parts = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                 return parts.map { part in
                     let tokens = part.split(separator: " ").map(String.init)
                     if tokens.count == 3 && tokens[1] == "as" {
                         return "__esm_export(module, '\(tokens[2])', function() { return \(tokens[0]); });"
                     }
                     return "__esm_export(module, '\(tokens[0])', function() { return \(tokens[0]); });"
                 }.joined(separator: "\n")
             }),
        ]

        for (regex, transformer) in patterns {
            result = applyRegex(regex, to: result, excluded: excluded, transformer: transformer)
        }

        return result
    }

    /// Extract declared variable names from a const/let/var declaration.
    private static func extractDeclaredNames(from decl: String) -> [String] {
        var names: [String] = []
        var trimmed = decl
        for keyword in ["const ", "let ", "var "] {
            if trimmed.hasPrefix(keyword) {
                trimmed = String(trimmed.dropFirst(keyword.count))
                break
            }
        }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            var inBracket = 0
            var current = ""
            for ch in trimmed {
                if ch == "{" || ch == "[" { inBracket += 1; continue }
                if ch == "}" || ch == "]" { inBracket -= 1; continue }
                if ch == "=" && inBracket == 0 { break }
                if ch == "," && inBracket <= 0 {
                    let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: ":").last.map(String.init)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
                        names.append(name)
                    }
                    current = ""
                    continue
                }
                if inBracket > 0 { current.append(ch) }
            }
            let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
                names.append(name)
            }
        } else {
            var depth = 0
            var current = ""
            for ch in trimmed {
                if ch == "(" || ch == "[" || ch == "{" { depth += 1 }
                if ch == ")" || ch == "]" || ch == "}" { depth -= 1 }
                if ch == "," && depth == 0 {
                    if let name = extractSimpleName(from: current) { names.append(name) }
                    current = ""
                    continue
                }
                current.append(ch)
            }
            if let name = extractSimpleName(from: current) { names.append(name) }
        }

        return names
    }

    private static func extractSimpleName(from s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let eqIdx = trimmed.firstIndex(of: "=") {
            name = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = trimmed
        }
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "; \t\n"))
        if !clean.isEmpty && clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
            return clean
        }
        return nil
    }

    // MARK: - import.meta

    private static func transformImportMeta(_ source: String, excluded: [ExcludedRange]) -> String {
        guard source.contains("import.meta") else { return source }

        var result = ""
        let nsSource = source as NSString
        let regex = try! NSRegularExpression(pattern: #"import\.meta"#)
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var lastEnd = 0
        for match in matches {
            let range = match.range
            if isInExcluded(range.location, excluded) { continue }
            result += nsSource.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            result += "import_meta"
            lastEnd = range.location + range.length
        }
        result += nsSource.substring(from: lastEnd)
        return result
    }

    // MARK: - Dynamic import()

    private static func transformDynamicImportInSource(_ source: String, excluded: [ExcludedRange]) -> String {
        guard source.contains("import(") else { return source }

        var result = ""
        let nsSource = source as NSString
        let regex = try! NSRegularExpression(pattern: #"(?<![.\w])import\s*\("#)
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var lastEnd = 0
        for match in matches {
            let range = match.range
            if isInExcluded(range.location, excluded) { continue }
            result += nsSource.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            result += "__importDynamic("
            lastEnd = range.location + range.length
        }
        result += nsSource.substring(from: lastEnd)

        if result.contains("__importDynamic(") {
            result = addDirnameToImportDynamic(result)
        }
        return result
    }

    private static func addDirnameToImportDynamic(_ source: String) -> String {
        var result = ""
        let marker = "__importDynamic("
        var searchStart = source.startIndex

        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            result += source[searchStart..<markerRange.lowerBound]
            result += marker

            var depth = 1
            var i = markerRange.upperBound
            while i < source.endIndex && depth > 0 {
                let ch = source[i]
                if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
                if depth > 0 { i = source.index(after: i) }
            }

            if depth == 0 {
                let argContent = source[markerRange.upperBound..<i]
                result += argContent
                result += ", __dirname)"
                searchStart = source.index(after: i)
            } else {
                result += source[markerRange.upperBound...]
                searchStart = source.endIndex
            }
        }

        result += source[searchStart...]
        return result
    }

    // MARK: - Helpers

    private static func substr(_ source: String, _ range: NSRange) -> String {
        return (source as NSString).substring(with: range)
    }

    /// Apply a regex transformation, skipping matches inside excluded ranges.
    /// Processes matches from bottom to top to preserve offsets.
    private static func applyRegex(
        _ regex: NSRegularExpression,
        to source: String,
        excluded: [ExcludedRange],
        transformer: (String, NSTextCheckingResult) -> String?
    ) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var result = source
        for match in matches.reversed() {
            let range = match.range
            if isInExcluded(range.location, excluded) { continue }

            if let replacement = transformer(result, match) {
                var replaceRange = range
                let matchStr = (result as NSString).substring(with: range)
                // Preserve leading newline or semicolon
                if let first = matchStr.first, (first == "\n" || first == ";") {
                    replaceRange = NSRange(location: range.location + 1, length: range.length - 1)
                }
                result = (result as NSString).replacingCharacters(in: replaceRange, with: replacement)
            }
        }

        return result
    }
}

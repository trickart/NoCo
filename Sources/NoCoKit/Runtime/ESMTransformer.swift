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
        result = transformDynamicImportInSource(result, excluded: buildExcludedRanges(in: result), dirnameVar: "__noco_dirname__")

        // 5. Prepend import_meta definition and __esModule marker (single line to preserve line numbers)
        let header = "Object.defineProperty(module.exports, '__esModule', {value: true}); var import_meta = Object.freeze({ url: 'file://' + __noco_filename__, dirname: __noco_dirname__, filename: __noco_filename__, resolve: function(specifier) { return 'file://' + require('path').resolve(__noco_dirname__, specifier); } });"
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

            // Single/double-quoted string literals
            if ch == 0x27 || ch == 0x22 {
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

            // Template literal
            if ch == 0x60 {
                i = scanTemplateLiteral(chars: chars, len: len, from: i, ranges: &ranges)
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

    /// Scan a template literal starting at the opening backtick.
    /// Text segments (outside `${}`) are added as excluded ranges.
    /// Expression segments (`${}` interiors) are NOT excluded so transforms apply inside them.
    /// Returns the index after the closing backtick.
    private static func scanTemplateLiteral(
        chars: [UInt16], len: Int, from start: Int, ranges: inout [ExcludedRange]
    ) -> Int {
        var i = start + 1  // skip opening backtick
        var textStart = start  // include opening backtick in first text segment

        while i < len {
            let ch = chars[i]

            // Escape sequence
            if ch == 0x5C {
                i += 2
                continue
            }

            // Closing backtick — end of template literal
            if ch == 0x60 {
                i += 1  // skip closing backtick
                ranges.append(ExcludedRange(start: textStart, end: i))
                return i
            }

            // Start of expression: ${
            if ch == 0x24 && i + 1 < len && chars[i + 1] == 0x7B {
                // Add text segment up to (including) ${ as excluded
                let exprOpen = i + 2
                ranges.append(ExcludedRange(start: textStart, end: exprOpen))

                // Scan inside ${...} — this is code, NOT excluded
                i = exprOpen
                var braceDepth = 1
                while i < len && braceDepth > 0 {
                    let c = chars[i]

                    // Nested template literal — recurse
                    if c == 0x60 {
                        i = scanTemplateLiteral(chars: chars, len: len, from: i, ranges: &ranges)
                        continue
                    }

                    // String literals inside expression
                    if c == 0x27 || c == 0x22 {
                        let q = c
                        let sStart = i
                        i += 1
                        while i < len {
                            if chars[i] == 0x5C { i += 2; continue }
                            if chars[i] == q { i += 1; break }
                            i += 1
                        }
                        ranges.append(ExcludedRange(start: sStart, end: i))
                        continue
                    }

                    // Single-line comment
                    if c == 0x2F && i + 1 < len && chars[i + 1] == 0x2F {
                        let cStart = i
                        i += 2
                        while i < len && chars[i] != 0x0A { i += 1 }
                        ranges.append(ExcludedRange(start: cStart, end: i))
                        continue
                    }

                    // Multi-line comment
                    if c == 0x2F && i + 1 < len && chars[i + 1] == 0x2A {
                        let cStart = i
                        i += 2
                        while i + 1 < len {
                            if chars[i] == 0x2A && chars[i + 1] == 0x2F {
                                i += 2
                                break
                            }
                            i += 1
                        }
                        ranges.append(ExcludedRange(start: cStart, end: i))
                        continue
                    }

                    // Regex literal inside expression (heuristic)
                    if c == 0x2F {
                        let prevNonSpace = findPrevNonSpace(chars, before: i)
                        let isRegex: Bool
                        if prevNonSpace < 0 {
                            isRegex = true
                        } else {
                            let prev = chars[prevNonSpace]
                            isRegex = [0x3D, 0x28, 0x5B, 0x21, 0x26, 0x7C, 0x3F, 0x3A, 0x2C, 0x3B, 0x7B, 0x7D, 0x0A, 0x0D].contains(prev)
                        }
                        if isRegex {
                            let rStart = i
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
                            ranges.append(ExcludedRange(start: rStart, end: i))
                            continue
                        }
                    }

                    if c == 0x7B { braceDepth += 1 }
                    else if c == 0x7D { braceDepth -= 1 }

                    if braceDepth > 0 { i += 1 }
                }

                // braceDepth == 0: closing } found, i points at }
                if braceDepth == 0 {
                    i += 1  // skip closing }
                }
                textStart = i - 1  // start next text segment from the closing }
                continue
            }

            i += 1
        }

        // Unterminated template literal — exclude what we have
        if i > textStart {
            ranges.append(ExcludedRange(start: textStart, end: i))
        }
        return i
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
        var exc = excluded

        // import x, { a, b } from 'y'  (default + named)
        result = applyRegex(
            /(?:^|\n|;)\s*import\s+([\w$]+)\s*,\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let defaultName = String(match.output.1)
            let named = String(match.output.2).trimmingCharacters(in: .whitespacesAndNewlines)
            let specifier = String(match.output.3)
            let destructured = transformNamedImports(named)
            return "var __m = __esm_import('\(specifier)', __noco_dirname__); var \(defaultName) = __m.default; var { \(destructured) } = __m;"
        }
        exc = buildExcludedRanges(in: result)

        // import * as ns from 'y'
        result = applyRegex(
            /(?:^|\n|;)\s*import\s*\*\s*as\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let ns = String(match.output.1)
            let specifier = String(match.output.2)
            return "var \(ns) = __esm_import('\(specifier)', __noco_dirname__);"
        }
        exc = buildExcludedRanges(in: result)

        // import { a, b } from 'y'
        result = applyRegex(
            /(?:^|\n|;)\s*import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let named = String(match.output.1)
            let specifier = String(match.output.2)
            let destructured = transformNamedImports(named)
            return "var { \(destructured) } = __esm_import('\(specifier)', __noco_dirname__);"
        }
        exc = buildExcludedRanges(in: result)

        // import x from 'y'
        result = applyRegex(
            /(?:^|\n|;)\s*import\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let name = String(match.output.1)
            let specifier = String(match.output.2)
            return "var __m = __esm_import('\(specifier)', __noco_dirname__); var \(name) = __m.default;"
        }
        exc = buildExcludedRanges(in: result)

        // import 'y'  (side-effect only)
        result = applyRegex(
            /(?:^|\n|;)\s*import\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let specifier = String(match.output.1)
            return "__esm_import('\(specifier)', __noco_dirname__);"
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
        var exc = excluded

        // export default function name(...) {
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+default\s+((?:async\s+)?function\s*\*?\s*([\w$]+)\s*\([^)]*\)\s*\{)/,
            to: result, excluded: exc
        ) { match in
            let funcDecl = String(match.output.1)
            let name = String(match.output.2)
            return "__esm_export_default(module, \(name));\n\(funcDecl)"
        }
        exc = buildExcludedRanges(in: result)

        // export default class Name {
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+default\s+(class\s+([\w$]+)\s*(?:extends\s+[^{]+)?\{)/,
            to: result, excluded: exc
        ) { match in
            let classDecl = String(match.output.1)
            let name = String(match.output.2)
            return "__esm_export(module, 'default', function() { return \(name); });\n\(classDecl)"
        }
        exc = buildExcludedRanges(in: result)

        // export default expr (must come after function/class)
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+default\s+(?!function\b|class\b)(.+)/,
            to: result, excluded: exc
        ) { match in
            var expr = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if expr.hasSuffix(";") { expr = String(expr.dropLast()) }
            return "__esm_export_default(module, \(expr));"
        }
        exc = buildExcludedRanges(in: result)

        // export { a, b } from 'y'  (re-export named)
        result = applyRegex(
            /(?:^|\n|;)\s*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let named = String(match.output.1)
            let specifier = String(match.output.2)
            let parts = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var exportLines: [String] = []
            for part in parts {
                let tokens = part.split(separator: " ").map(String.init)
                if tokens.count == 3 && tokens[1] == "as" {
                    exportLines.append("__esm_export(module, '\(tokens[2])', function() { return __re.\(tokens[0]); });")
                } else if tokens.count == 1 {
                    exportLines.append("__esm_export(module, '\(tokens[0])', function() { return __re.\(tokens[0]); });")
                }
            }
            return "(function() { var __re = __esm_import('\(specifier)', __noco_dirname__); \(exportLines.joined(separator: " ")) })();"
        }
        exc = buildExcludedRanges(in: result)

        // export * from 'y'
        result = applyRegex(
            /(?:^|\n|;)\s*export\s*\*\s*from\s*['"]([^'"]+)['"]/,
            to: result, excluded: exc
        ) { match in
            let specifier = String(match.output.1)
            return "__esm_export_star(module, __esm_import('\(specifier)', __noco_dirname__));"
        }
        exc = buildExcludedRanges(in: result)

        // export function name(...) {
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+((?:async\s+)?function\s*\*?\s*([\w$]+)\s*\([^)]*\)\s*\{)/,
            to: result, excluded: exc
        ) { match in
            let funcDecl = String(match.output.1)
            let name = String(match.output.2)
            return "__esm_export(module, '\(name)', function() { return \(name); });\n\(funcDecl)"
        }
        exc = buildExcludedRanges(in: result)

        // export class Name {
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+(class\s+([\w$]+)\s*(?:extends\s+[^{]+)?\{)/,
            to: result, excluded: exc
        ) { match in
            let classDecl = String(match.output.1)
            let name = String(match.output.2)
            return "__esm_export(module, '\(name)', function() { return \(name); });\n\(classDecl)"
        }
        exc = buildExcludedRanges(in: result)

        // export const/let/var
        result = applyRegex(
            /(?:^|\n|;)\s*export\s+((?:const|let|var)\s+.+)/,
            to: result, excluded: exc
        ) { match in
            let decl = String(match.output.1)
            let names = extractDeclaredNames(from: decl)
            let exports = names.map { "__esm_export(module, '\($0)', function() { return \($0); });" }
            return "\(decl)\n\(exports.joined(separator: "\n"))"
        }
        exc = buildExcludedRanges(in: result)

        // export { a, b }  (local re-export, no 'from')
        result = applyRegex(
            /(?:^|\n|;)\s*export\s*\{([^}]*)\}\s*(?:;|\n|$)/,
            to: result, excluded: exc
        ) { match in
            let named = String(match.output.1)
            let parts = named.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.map { part in
                let tokens = part.split(separator: " ").map(String.init)
                if tokens.count == 3 && tokens[1] == "as" {
                    return "__esm_export(module, '\(tokens[2])', function() { return \(tokens[0]); });"
                }
                return "__esm_export(module, '\(tokens[0])', function() { return \(tokens[0]); });"
            }.joined(separator: "\n")
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

        let regex = /import\.meta/
        let matches = source.matches(of: regex)
        guard !matches.isEmpty else { return source }

        var result = ""
        var lastEnd = source.startIndex
        for match in matches {
            let utf16Offset = source.utf16.distance(from: source.startIndex, to: match.range.lowerBound)
            if isInExcluded(utf16Offset, excluded) { continue }
            result += source[lastEnd..<match.range.lowerBound]
            result += "import_meta"
            lastEnd = match.range.upperBound
        }
        result += source[lastEnd...]
        return result
    }

    // MARK: - Dynamic import()

    private static func transformDynamicImportInSource(_ source: String, excluded: [ExcludedRange], dirnameVar: String = "__dirname") -> String {
        guard source.contains("import(") else { return source }

        // Use a regex that captures an optional preceding character to simulate lookbehind.
        // Group 1 captures the char before "import(" if present; we skip if it's [.\w].
        let regex = /(^|[^.\w$])import\s*\(/
        let matches = source.matches(of: regex)
        guard !matches.isEmpty else { return source }

        var result = ""
        var lastEnd = source.startIndex
        for match in matches {
            let utf16Offset = source.utf16.distance(from: source.startIndex, to: match.range.lowerBound)
            if isInExcluded(utf16Offset, excluded) { continue }
            // The prefix char (group 1) must be preserved, only replace from after it
            let prefixEnd = match.output.1.endIndex
            result += source[lastEnd..<prefixEnd]
            result += "__importDynamic("
            lastEnd = match.range.upperBound
        }
        result += source[lastEnd...]

        if result.contains("__importDynamic(") {
            result = addDirnameToImportDynamic(result, dirnameVar: dirnameVar)
        }
        return result
    }

    private static func addDirnameToImportDynamic(_ source: String, dirnameVar: String = "__noco_dirname__") -> String {
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
                result += ", \(dirnameVar))"
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

    /// Apply a regex transformation, skipping matches inside excluded ranges.
    /// Processes matches from bottom to top to preserve offsets.
    private static func applyRegex<Output>(
        _ regex: Regex<Output>,
        to source: String,
        excluded: [ExcludedRange],
        transformer: (Regex<Output>.Match) -> String?
    ) -> String {
        let matches = source.matches(of: regex)
        guard !matches.isEmpty else { return source }

        let records: [(match: Regex<Output>.Match, utf16Offset: Int, utf16Length: Int)] = matches.map { match in
            let offset = source.utf16.distance(from: source.startIndex, to: match.range.lowerBound)
            let length = source.utf16.distance(from: match.range.lowerBound, to: match.range.upperBound)
            return (match, offset, length)
        }

        var result = source
        for record in records.reversed() {
            if isInExcluded(record.utf16Offset, excluded) { continue }

            if let replacement = transformer(record.match) {
                var replaceOffset = record.utf16Offset
                var replaceLength = record.utf16Length

                let matchStr = String(source[record.match.range])
                if let first = matchStr.first, (first == "\n" || first == ";") {
                    replaceOffset += 1
                    replaceLength -= 1
                }

                let startIdx = result.utf16.index(result.utf16.startIndex, offsetBy: replaceOffset)
                let endIdx = result.utf16.index(startIdx, offsetBy: replaceLength)
                result.replaceSubrange(startIdx..<endIdx, with: replacement)
            }
        }

        return result
    }
}

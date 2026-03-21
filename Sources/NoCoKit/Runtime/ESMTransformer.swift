import Foundation

/// Transforms ESM import/export syntax into ESM runtime calls.
/// Uses regex-based parsing with comment/string exclusion.
public enum ESMTransformer {

    // MARK: - Public API

    /// Transform ESM source (import/export) into ESM runtime calls.
    /// Used for files detected as ESM.
    public static func transform(_ source: String) -> String {
        var result = source
        var exc = buildExcludedRanges(in: result)

        // 1. Transform imports
        result = transformImports(result, excluded: &exc)

        // 2. Transform exports
        result = transformExports(result, excluded: &exc)

        // 3. Add import.meta support
        result = transformImportMeta(result, excluded: exc)

        // 4. Transform dynamic import() — applies to all files
        result = transformDynamicImportInSource(result, excluded: exc, dirnameVar: "__noco_dirname__")

        // 5. Prepend import_meta definition and __esModule marker (single line to preserve line numbers)
        let header = "Object.defineProperty(module.exports, '__esModule', {value: true}); var import_meta = Object.freeze({ url: 'file://' + __noco_filename__, dirname: __noco_dirname__, filename: __noco_filename__, resolve: function(specifier) { return 'file://' + require('path').resolve(__noco_dirname__, specifier); } });"
        result = header + result

        return result
    }

    /// Detect whether the source contains a top-level `await` (outside function/class/arrow scopes).
    /// Control-flow braces (if/for/while/switch/try/catch) do NOT create a new scope for TLA purposes.
    public static func containsTopLevelAwait(_ source: String) -> Bool {
        let excluded = buildExcludedRanges(in: source)
        let chars = Array(source.utf16)
        let len = chars.count
        var i = 0

        // Track brace depth with a stack: each entry indicates whether
        // the brace opened a function/class/arrow scope (true) or a
        // control-flow/object brace (false). `await` is only top-level
        // when no function-scope brace is on the stack.
        var functionScopeDepth = 0
        var braceStack: [Bool] = [] // true = function/class/arrow scope

        // Helper: check if position is in excluded range (binary search)
        func inExcluded(_ pos: Int) -> Bool {
            var lo = 0
            var hi = excluded.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = excluded[mid]
                if pos < r.start {
                    hi = mid - 1
                } else if pos >= r.end {
                    lo = mid + 1
                } else {
                    return true
                }
            }
            return false
        }

        func skipExcluded() {
            while i < len && inExcluded(i) {
                for r in excluded { if r.contains(i) { i = r.end; break } }
            }
        }

        // Helper: skip whitespace/newlines
        func skipWhitespace() {
            while i < len {
                let ch = chars[i]
                if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
                    i += 1
                } else { break }
            }
        }

        // Helper: check if chars[pos..] matches a keyword (UTF-16)
        func matchKeyword(_ keyword: [UInt16], at pos: Int) -> Bool {
            guard pos + keyword.count <= len else { return false }
            for j in 0..<keyword.count {
                if chars[pos + j] != keyword[j] { return false }
            }
            let afterPos = pos + keyword.count
            if afterPos < len && isIdentChar(chars[afterPos]) { return false }
            if pos > 0 && isIdentChar(chars[pos - 1]) { return false }
            return true
        }

        func pushBrace(isFunctionScope: Bool) {
            braceStack.append(isFunctionScope)
            if isFunctionScope { functionScopeDepth += 1 }
        }

        func popBrace() {
            if let isFunction = braceStack.popLast(), isFunction {
                functionScopeDepth -= 1
            }
        }

        /// Skip function params (...) and open brace, pushing a function scope
        func skipFunctionParamsAndOpenBrace() {
            skipWhitespace()
            skipExcluded()
            // Skip optional * for generator
            if i < len && chars[i] == 0x2A { i += 1; skipWhitespace() }
            // Skip function name if present
            if i < len && isIdentChar(chars[i]) {
                while i < len && isIdentChar(chars[i]) { i += 1 }
                skipWhitespace()
            }
            // Skip params (...)
            if i < len && chars[i] == 0x28 {
                var depth = 1
                i += 1
                while i < len && depth > 0 {
                    if inExcluded(i) { skipExcluded(); continue }
                    if chars[i] == 0x28 { depth += 1 }
                    else if chars[i] == 0x29 { depth -= 1 }
                    i += 1
                }
                skipWhitespace()
            }
            // Expect {
            if i < len && chars[i] == 0x7B {
                pushBrace(isFunctionScope: true)
                i += 1
            }
        }

        let kw_function: [UInt16] = Array("function".utf16)
        let kw_class: [UInt16] = Array("class".utf16)
        let kw_async: [UInt16] = Array("async".utf16)
        let kw_await: [UInt16] = Array("await".utf16)

        while i < len {
            if inExcluded(i) { skipExcluded(); continue }

            let ch = chars[i]

            // Check for "await" outside any function/class/arrow scope
            if functionScopeDepth == 0 && matchKeyword(kw_await, at: i) {
                return true
            }

            // "async" possibly followed by "function"
            if matchKeyword(kw_async, at: i) {
                let savedI = i
                i += kw_async.count
                skipWhitespace()
                skipExcluded()
                if matchKeyword(kw_function, at: i) {
                    i += kw_function.count
                    skipFunctionParamsAndOpenBrace()
                    continue
                }
                i = savedI + 1
                continue
            }

            // "function" keyword
            if matchKeyword(kw_function, at: i) {
                i += kw_function.count
                skipFunctionParamsAndOpenBrace()
                continue
            }

            // "class" keyword — skip entire class body using brace depth
            if matchKeyword(kw_class, at: i) {
                i += kw_class.count
                skipWhitespace()
                if i < len && isIdentChar(chars[i]) {
                    while i < len && isIdentChar(chars[i]) { i += 1 }
                    skipWhitespace()
                }
                let kw_extends: [UInt16] = Array("extends".utf16)
                if matchKeyword(kw_extends, at: i) {
                    i += kw_extends.count
                    while i < len && chars[i] != 0x7B {
                        if inExcluded(i) { skipExcluded(); continue }
                        i += 1
                    }
                }
                if i < len && chars[i] == 0x7B {
                    var depth = 1
                    i += 1
                    while i < len && depth > 0 {
                        if inExcluded(i) { skipExcluded(); continue }
                        if chars[i] == 0x7B { depth += 1 }
                        else if chars[i] == 0x7D { depth -= 1 }
                        if depth > 0 { i += 1 }
                    }
                    if i < len { i += 1 }
                }
                continue
            }

            // Arrow function: => { opens a function scope
            if ch == 0x3D && i + 1 < len && chars[i + 1] == 0x3E {
                i += 2
                skipWhitespace()
                if i < len && chars[i] == 0x7B {
                    pushBrace(isFunctionScope: true)
                    i += 1
                }
                continue
            }

            // Opening brace (control flow, object literal, etc.)
            if ch == 0x7B {
                pushBrace(isFunctionScope: false)
                i += 1
                continue
            }

            // Closing brace
            if ch == 0x7D {
                popBrace()
                i += 1
                continue
            }

            i += 1
        }

        return false
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
        var lo = 0
        var hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if offset < r.start {
                hi = mid - 1
            } else if offset >= r.end {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Import Transformation

    private static func transformImports(_ source: String, excluded: inout [ExcludedRange]) -> String {
        var result = source

        // import x, { a, b } from 'y'  (default + named)
        result = applyPattern(
            #"(?:^|\n|;)\s*import\s+([\w$]+)\s*,\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let defaultName = groups[1]
            let named = groups[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let specifier = groups[3]
            let destructured = transformNamedImports(named)
            return "var __m = __esm_import('\(specifier)', __noco_dirname__); var \(defaultName) = __m.default; var { \(destructured) } = __m;"
        }

        // import * as ns from 'y'
        result = applyPattern(
            #"(?:^|\n|;)\s*import\s*\*\s*as\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let ns = groups[1]
            let specifier = groups[2]
            return "var \(ns) = __esm_import('\(specifier)', __noco_dirname__);"
        }

        // import { a, b } from 'y'
        result = applyPattern(
            #"(?:^|\n|;)\s*import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let named = groups[1]
            let specifier = groups[2]
            let destructured = transformNamedImports(named)
            return "var { \(destructured) } = __esm_import('\(specifier)', __noco_dirname__);"
        }

        // import x from 'y'
        result = applyPattern(
            #"(?:^|\n|;)\s*import\s+([\w$]+)\s+from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded,
        ) { groups in
            let name = groups[1]
            let specifier = groups[2]
            return "var __m = __esm_import('\(specifier)', __noco_dirname__); var \(name) = __m.default;"
        }

        // import 'y'  (side-effect only)
        result = applyPattern(
            #"(?:^|\n|;)\s*import\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let specifier = groups[1]
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

    private static func transformExports(_ source: String, excluded: inout [ExcludedRange]) -> String {
        var result = source

        // export default function name(...) {
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s+default\s+((?:async\s+)?function\s*\*?\s*([\w$]+)\s*\([^)]*\)\s*\{)"#,
            to: result, excluded: &excluded
        ) { groups in
            let funcDecl = groups[1]
            let name = groups[2]
            return "__esm_export_default(module, \(name));\n\(funcDecl)"
        }

        // export default class Name {
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s+default\s+(class\s+([\w$]+)\s*(?:extends\s+[^{]+)?\{)"#,
            to: result, excluded: &excluded
        ) { groups in
            let classDecl = groups[1]
            let name = groups[2]
            return "__esm_export(module, 'default', function() { return \(name); });\n\(classDecl)"
        }

        // export default expr (must come after function/class)
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s+default\s+(?!function\b|class\b)(.+)"#,
            to: result, excluded: &excluded
        ) { groups in
            var expr = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if expr.hasSuffix(";") { expr = String(expr.dropLast()) }
            return "__esm_export_default(module, \(expr));"
        }

        // export { a, b } from 'y'  (re-export named)
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let named = groups[1]
            let specifier = groups[2]
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

        // export * from 'y'
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s*\*\s*from\s*['"]([^'"]+)['"]"#,
            to: result, excluded: &excluded
        ) { groups in
            let specifier = groups[1]
            return "__esm_export_star(module, __esm_import('\(specifier)', __noco_dirname__));"
        }

        // export function name(...) {
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s+((?:async\s+)?function\s*\*?\s*([\w$]+)\s*\([^)]*\)\s*\{)"#,
            to: result, excluded: &excluded
        ) { groups in
            let funcDecl = groups[1]
            let name = groups[2]
            return "__esm_export(module, '\(name)', function() { return \(name); });\n\(funcDecl)"
        }

        // export class Name {
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s+(class\s+([\w$]+)\s*(?:extends\s+[^{]+)?\{)"#,
            to: result, excluded: &excluded
        ) { groups in
            let classDecl = groups[1]
            let name = groups[2]
            return "__esm_export(module, '\(name)', function() { return \(name); });\n\(classDecl)"
        }

        // export const/let/var
        result = transformExportVarDeclarations(result, excluded: excluded)
        // Rebuild excluded ranges after var declarations (uses different processing)
        excluded = buildExcludedRanges(in: result)

        // export { a, b }  (local re-export, no 'from')
        result = applyPattern(
            #"(?:^|\n|;)\s*export\s*\{([^}]*)\}\s*(?:;|\n|$)"#,
            to: result, excluded: &excluded
        ) { groups in
            let named = groups[1]
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

    /// Transform `export const/let/var` declarations, handling minified code where
    /// multiple export statements appear on the same line separated by semicolons.
    /// Uses bracket-depth tracking to find statement boundaries instead of greedy `.+`.
    private static func transformExportVarDeclarations(_ source: String, excluded: [ExcludedRange]) -> String {
        guard let headerRegex = try? NSRegularExpression(pattern: #"(?:^|\n|;)\s*export\s+(?:const|let|var)\s+"#) else { return source }
        let nsSource = source as NSString
        let nsMatches = headerRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !nsMatches.isEmpty else { return source }

        var result = source
        // Process in reverse to preserve offsets
        for nsMatch in nsMatches.reversed() {
            let matchRange = nsMatch.range
            let utf16Offset = matchRange.location
            if isInExcluded(utf16Offset, excluded) { continue }

            let matchStr = nsSource.substring(with: matchRange)
            // Skip the leading separator (newline or semicolon)
            var replaceUTF16Start = utf16Offset
            if let first = matchStr.first, first == "\n" || first == ";" {
                replaceUTF16Start += 1
            }
            // Skip leading whitespace after separator
            while replaceUTF16Start < nsSource.length {
                let ch = nsSource.character(at: replaceUTF16Start)
                if ch == 0x20 || ch == 0x09 { replaceUTF16Start += 1 } else { break }
            }

            let replaceStart = source.utf16.index(source.utf16.startIndex, offsetBy: replaceUTF16Start)

            // Find the "export " prefix end — we need to skip past "export " to get the declaration
            let afterExportUTF16 = utf16Offset + matchRange.length
            let afterExport = source.utf16.index(source.utf16.startIndex, offsetBy: afterExportUTF16)

            // Find the end of this statement by tracking bracket depth
            var depth = 0
            var i = afterExport
            var inSingleQuote = false
            var inDoubleQuote = false
            var inTemplate = false
            var prevChar: Character = " "
            while i < source.endIndex {
                let ch = source[i]
                if !inSingleQuote && !inDoubleQuote && !inTemplate {
                    if ch == "'" { inSingleQuote = true }
                    else if ch == "\"" { inDoubleQuote = true }
                    else if ch == "`" { inTemplate = true }
                    else if ch == "(" || ch == "[" || ch == "{" { depth += 1 }
                    else if ch == ")" || ch == "]" || ch == "}" {
                        depth -= 1
                        if depth < 0 { break }
                    }
                    else if depth == 0 {
                        if ch == ";" { break }
                        if ch == "\n" {
                            // Check if next non-whitespace is a new statement (not a continuation)
                            var j = source.index(after: i)
                            while j < source.endIndex && (source[j] == " " || source[j] == "\t") {
                                j = source.index(after: j)
                            }
                            // If the next token starts with a keyword/identifier that looks like
                            // a new statement, break here
                            if j < source.endIndex {
                                let remaining = source[j...]
                                if remaining.hasPrefix("export ") || remaining.hasPrefix("import ") ||
                                   remaining.hasPrefix("//") || remaining.hasPrefix("/*") {
                                    break
                                }
                            }
                        }
                    }
                } else if inSingleQuote {
                    if ch == "'" && prevChar != "\\" { inSingleQuote = false }
                } else if inDoubleQuote {
                    if ch == "\"" && prevChar != "\\" { inDoubleQuote = false }
                } else if inTemplate {
                    if ch == "`" && prevChar != "\\" { inTemplate = false }
                }
                prevChar = ch
                i = source.index(after: i)
            }

            let stmtEnd = i
            let fullDecl = String(source[afterExport..<stmtEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Get just the declaration part (without "export ")
            // afterExport already points past "export const/let/var "
            // But we need the keyword for the output
            let exportAndDecl = String(source[replaceStart..<stmtEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove trailing semicolon for clean processing
            let declForNames: String
            if exportAndDecl.hasSuffix(";") {
                declForNames = String(fullDecl.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                declForNames = fullDecl
            }

            // Extract the const/let/var keyword + rest for name extraction
            let keywordAndRest: String
            if let spaceIdx = exportAndDecl.dropFirst("export ".count).firstIndex(of: " ") {
                // "export const foo = 1" -> "const foo = 1"
                keywordAndRest = String(exportAndDecl.dropFirst("export ".count))
            } else {
                keywordAndRest = String(exportAndDecl.dropFirst("export ".count))
            }

            let names = extractDeclaredNames(from: keywordAndRest)
            let exports = names.map { "__esm_export(module, '\($0)', function() { return \($0); });" }

            // Build replacement: remove "export " prefix, keep the declaration, append exports
            let declOnly = String(exportAndDecl.dropFirst("export ".count))
            let replacement = "\(declOnly)\n\(exports.joined(separator: "\n"))"

            // Replace in result using the corresponding positions
            let resultReplaceStart = result.utf16.index(
                result.utf16.startIndex,
                offsetBy: source.utf16.distance(from: source.startIndex, to: replaceStart)
            )
            let resultReplaceEnd = result.utf16.index(
                result.utf16.startIndex,
                offsetBy: source.utf16.distance(from: source.startIndex, to: stmtEnd)
            )
            result.replaceSubrange(resultReplaceStart..<resultReplaceEnd, with: replacement)
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

        guard let nsRegex = try? NSRegularExpression(pattern: #"import\.meta"#) else { return source }
        let nsSource = source as NSString
        let nsMatches = nsRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !nsMatches.isEmpty else { return source }

        var result = ""
        var lastEnd = 0
        for nsMatch in nsMatches {
            let utf16Offset = nsMatch.range.location
            if isInExcluded(utf16Offset, excluded) { continue }
            let beforeStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
            let beforeEnd = source.utf16.index(source.utf16.startIndex, offsetBy: utf16Offset)
            result += source[beforeStart..<beforeEnd]
            result += "import_meta"
            lastEnd = utf16Offset + nsMatch.range.length
        }
        let remainStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
        result += source[remainStart...]
        return result
    }

    // MARK: - Dynamic import()

    private static func transformDynamicImportInSource(_ source: String, excluded: [ExcludedRange], dirnameVar: String = "__dirname") -> String {
        guard source.contains("import(") else { return source }

        // Group 1 captures the char before "import(" if present; we skip if it's [.\w].
        guard let nsRegex = try? NSRegularExpression(pattern: #"(^|[^.\w$])import\s*\("#) else { return source }
        let nsSource = source as NSString
        let nsMatches = nsRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !nsMatches.isEmpty else { return source }

        var result = ""
        var lastEnd = 0
        for nsMatch in nsMatches {
            let utf16Offset = nsMatch.range.location
            if isInExcluded(utf16Offset, excluded) { continue }

            // メソッド定義 "import(" を dynamic import と区別する:
            // "async import(" は常にメソッド定義（async import('x') は JS 文法的に invalid）。
            // "import" の直前（空白スキップ）が "async" ならスキップ。
            let prefixRange = nsMatch.range(at: 1)
            let prefixEnd = prefixRange.location + prefixRange.length
            let importStart = prefixEnd // "import" の開始位置 (UTF-16)

            var scanPos = importStart
            while scanPos > 0 {
                let idx = source.utf16.index(source.utf16.startIndex, offsetBy: scanPos - 1)
                let ch = source[idx]
                if ch == " " || ch == "\t" { scanPos -= 1 } else { break }
            }
            if scanPos >= 5 {
                let asyncEnd = source.utf16.index(source.utf16.startIndex, offsetBy: scanPos)
                let asyncStart = source.utf16.index(source.utf16.startIndex, offsetBy: scanPos - 5)
                if String(source[asyncStart..<asyncEnd]) == "async" {
                    // "async" の前が識別子文字でないことを確認（"xasync" 等を除外）
                    if scanPos == 5 {
                        continue
                    }
                    let beforeIdx = source.utf16.index(source.utf16.startIndex, offsetBy: scanPos - 6)
                    let beforeCh = source[beforeIdx]
                    if !beforeCh.isLetter && !beforeCh.isNumber && beforeCh != "_" && beforeCh != "$" {
                        continue
                    }
                }
            }

            // The prefix char (group 1) must be preserved, only replace from after it
            let beforeStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
            let beforeEnd = source.utf16.index(source.utf16.startIndex, offsetBy: prefixEnd)
            result += source[beforeStart..<beforeEnd]
            result += "__importDynamic("
            lastEnd = utf16Offset + nsMatch.range.length
        }
        let remainStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
        result += source[remainStart...]

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

    /// Apply a pattern transformation using NSRegularExpression for performance on large strings.
    /// Uses forward concatenation and updates excluded ranges in-place.
    private static func applyPattern(
        _ pattern: String,
        to source: String,
        excluded: inout [ExcludedRange],
        transformer: ([String]) -> String?
    ) -> String {
        guard let nsRegex = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        let nsMatches = nsRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !nsMatches.isEmpty else { return source }

        var result = ""
        var lastEnd = 0  // UTF-16 offset
        var cumulativeDelta = 0
        for nsMatch in nsMatches {
            let matchRange = nsMatch.range
            let utf16Offset = matchRange.location
            let adjustedOffset = utf16Offset + cumulativeDelta
            if isInExcluded(adjustedOffset, excluded) { continue }

            // Extract capture groups
            var groups: [String] = []
            for g in 0..<nsMatch.numberOfRanges {
                let r = nsMatch.range(at: g)
                if r.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(nsSource.substring(with: r))
                }
            }

            guard let replacement = transformer(groups) else { continue }

            // Skip the leading \n or ; separator
            var replaceOffset = utf16Offset
            var skipCount = 0
            let matchStr = groups[0]
            if let first = matchStr.first, first == "\n" || first == ";" {
                replaceOffset += 1
                skipCount = 1
            }

            // Append text before this match, then the replacement
            let beforeStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
            let beforeEnd = source.utf16.index(source.utf16.startIndex, offsetBy: replaceOffset)
            result += source[beforeStart..<beforeEnd]
            result += replacement
            lastEnd = utf16Offset + matchRange.length

            // Calculate delta and update excluded ranges
            let originalUTF16Length = matchRange.length - skipCount
            let replacementUTF16Length = replacement.utf16.count
            let delta = replacementUTF16Length - originalUTF16Length
            let replacePos = replaceOffset + cumulativeDelta
            let replaceEnd = replacePos + originalUTF16Length
            // Remove excluded ranges that fall within the replaced match,
            // and shift ranges that come after the match
            excluded = excluded.compactMap { range in
                if range.start >= replacePos && range.end <= replaceEnd {
                    // Entirely within replaced region — remove
                    return nil
                }
                if range.start >= replaceEnd {
                    // After replaced region — shift by delta
                    return ExcludedRange(start: range.start + delta, end: range.end + delta)
                }
                return range
            }
            cumulativeDelta += delta
        }
        // Append remaining text
        let remainStart = source.utf16.index(source.utf16.startIndex, offsetBy: lastEnd)
        result += source[remainStart...]
        return result
    }
}

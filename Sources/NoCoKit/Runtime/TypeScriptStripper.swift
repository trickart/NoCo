import Foundation

/// Strips TypeScript type annotations from source code to produce valid JavaScript.
/// Uses a regex and scanner-based approach similar to ESMTransformer.
///
/// Supported:
/// - Type annotations (`: Type` on variables, parameters, return types)
/// - Type/interface/declare declarations
/// - import type / export type statements
/// - Generic type parameters on function/class declarations
/// - Type assertions (`as Type`, `satisfies Type`)
/// - Access modifiers (public/private/protected/abstract/override)
/// - readonly modifier, definite assignment (`!`), optional parameter marker (`?`)
/// - `implements` clause on classes
///
/// Not supported (v1):
/// - enum → object literal conversion
/// - namespace → IIFE conversion
/// - Constructor parameter properties (`constructor(public x: number)`)
public enum TypeScriptStripper {

    // MARK: - Public API

    /// Strip TypeScript type annotations from the source code.
    public static func strip(_ source: String) -> String {
        var result = source

        // Phase 1: Remove full TypeScript statements
        result = removeImportTypes(result)
        result = removeExportTypes(result)
        result = removeInterfaces(result)
        result = removeTypeAliases(result)
        result = removeDeclareStatements(result)

        // Phase 2: Remove inline type annotations
        result = removeImplementsClause(result)
        result = removeGenericTypeParameters(result)
        result = removeAccessModifiers(result)
        result = removeReadonlyModifier(result)
        result = removeDefiniteAssignment(result)
        result = removeFunctionReturnTypes(result)
        result = removeFunctionParamTypes(result)
        result = removeVariableTypeAnnotations(result)
        result = removeAsAssertions(result)
        result = removeSatisfiesExpressions(result)
        result = removeOptionalParamMarker(result)

        return result
    }

    // MARK: - Excluded Ranges (comments & strings)

    struct ExcludedRange {
        let start: Int
        let end: Int
        func contains(_ index: Int) -> Bool { index >= start && index < end }
    }

    static func buildExcludedRanges(in source: String) -> [ExcludedRange] {
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

            i += 1
        }

        return ranges
    }

    static func isInExcluded(_ offset: Int, _ ranges: [ExcludedRange]) -> Bool {
        for r in ranges {
            if r.contains(offset) { return true }
            if r.start > offset { break }
        }
        return false
    }

    // MARK: - Type Extent Scanner

    /// Scan forward from `start` to find the end of a type expression.
    /// Tracks `<>`, `()`, `{}`, `[]` depth. Returns the index of the first
    /// terminator character at depth 0.
    private static func scanTypeEnd(
        _ chars: [UInt16],
        from start: Int,
        terminators: Set<UInt16>
    ) -> Int {
        var i = start
        let len = chars.count
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0

        // Skip leading whitespace
        while i < len && isWhitespace(chars[i]) { i += 1 }

        while i < len {
            let ch = chars[i]
            let totalDepth = angleDepth + parenDepth + braceDepth + bracketDepth

            // At depth 0, check terminators
            if totalDepth == 0 && terminators.contains(ch) {
                return i
            }

            switch ch {
            case 0x3C: angleDepth += 1   // <
            case 0x3E:                     // >
                if angleDepth > 0 { angleDepth -= 1 }
                else { return i }
            case 0x28: parenDepth += 1    // (
            case 0x29:                     // )
                if parenDepth > 0 { parenDepth -= 1 }
                else { return i }
            case 0x7B: braceDepth += 1    // {
            case 0x7D:                     // }
                if braceDepth > 0 { braceDepth -= 1 }
                else { return i }
            case 0x5B: bracketDepth += 1  // [
            case 0x5D:                     // ]
                if bracketDepth > 0 { bracketDepth -= 1 }
                else { return i }
            case 0x27, 0x22, 0x60:        // string literals inside types
                let quote = ch
                i += 1
                while i < len {
                    if chars[i] == 0x5C { i += 2; continue }
                    if chars[i] == quote { break }
                    i += 1
                }
            default: break
            }

            i += 1
        }

        return len
    }

    /// Scan forward to find the matching closing brace `}`.
    /// Assumes `start` is the position right after the opening `{`.
    private static func scanMatchingBrace(
        _ chars: [UInt16], from start: Int
    ) -> Int {
        var i = start
        let len = chars.count
        var depth = 1

        while i < len && depth > 0 {
            let ch = chars[i]
            switch ch {
            case 0x7B: depth += 1
            case 0x7D: depth -= 1
            case 0x27, 0x22, 0x60:
                let quote = ch
                i += 1
                while i < len {
                    if chars[i] == 0x5C { i += 2; continue }
                    if chars[i] == quote { break }
                    i += 1
                }
            case 0x2F: // potential comment
                if i + 1 < len {
                    if chars[i + 1] == 0x2F {
                        i += 2
                        while i < len && chars[i] != 0x0A { i += 1 }
                        continue
                    }
                    if chars[i + 1] == 0x2A {
                        i += 2
                        while i + 1 < len {
                            if chars[i] == 0x2A && chars[i + 1] == 0x2F {
                                i += 1
                                break
                            }
                            i += 1
                        }
                    }
                }
            default: break
            }
            i += 1
        }

        return i // position after the closing `}`
    }

    // MARK: - Statement Removal

    private static func removeImportTypes(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        // import type { ... } from '...'
        // import type Name from '...'
        // import type * as Name from '...'
        let regex = try! NSRegularExpression(
            pattern: #"(?:^|\n)\s*import\s+type\s+(?:\{[^}]*\}|\*\s+as\s+\w+|\w+)\s+from\s+['"][^'"]*['"]\s*;?"#
        )
        return removeMatches(regex, in: source, excluded: excluded)
    }

    private static func removeExportTypes(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        // export type { ... } from '...'
        // export type { ... }
        let regex = try! NSRegularExpression(
            pattern: #"(?:^|\n)\s*export\s+type\s+\{[^}]*\}\s*(?:from\s+['"][^'"]*['"])?\s*;?"#
        )
        return removeMatches(regex, in: source, excluded: excluded)
    }

    private static func removeInterfaces(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // interface Name<...> extends ... {
        let regex = try! NSRegularExpression(
            pattern: #"(?:^|\n)\s*(?:export\s+)?interface\s+\w+"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            // Find the opening `{`
            var i = match.range.location + match.range.length
            while i < chars.count && chars[i] != 0x7B { i += 1 } // {
            if i >= chars.count { continue }

            // Find matching `}`
            let end = scanMatchingBrace(chars, from: i + 1)

            // Remove trailing semicolon if present
            var removeEnd = end
            let updatedChars = Array(result.utf16)
            if removeEnd < updatedChars.count && updatedChars[removeEnd] == 0x3B { removeEnd += 1 }

            var removeStart = match.range.location
            // Preserve leading newline
            let matchStr = nsSource.substring(with: match.range)
            if matchStr.hasPrefix("\n") { removeStart += 1 }

            let removeRange = NSRange(location: removeStart, length: removeEnd - removeStart)
            let replacement = preserveNewlines(in: result as NSString, range: removeRange)
            result = (result as NSString).replacingCharacters(in: removeRange, with: replacement)
        }

        return result
    }

    private static func removeTypeAliases(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // type Name<...> = ...;
        let regex = try! NSRegularExpression(
            pattern: #"(?:^|\n)\s*(?:export\s+)?type\s+\w+[^=]*="#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let afterEq = match.range.location + match.range.length

            // Scan the type value: ends at `;` at depth 0
            let typeEnd = scanTypeEnd(
                chars, from: afterEq,
                terminators: [0x3B] // ;
            )

            var removeEnd = typeEnd
            if removeEnd < chars.count && chars[removeEnd] == 0x3B { removeEnd += 1 }

            var removeStart = match.range.location
            let matchStr = nsSource.substring(with: match.range)
            if matchStr.hasPrefix("\n") { removeStart += 1 }

            let removeRange = NSRange(location: removeStart, length: removeEnd - removeStart)
            let replacement = preserveNewlines(in: result as NSString, range: removeRange)
            result = (result as NSString).replacingCharacters(in: removeRange, with: replacement)
        }

        return result
    }

    private static func removeDeclareStatements(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // declare const/let/var/function/class/module/namespace/enum/global/abstract/type/interface ...
        let regex = try! NSRegularExpression(
            pattern: #"(?:^|\n)\s*(?:export\s+)?declare\s+"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            var i = match.range.location + match.range.length

            // Find end: either `;` at depth 0 or matching `}` if a block
            var braceDepth = 0
            var foundBrace = false
            while i < chars.count {
                let ch = chars[i]
                if ch == 0x7B { braceDepth += 1; foundBrace = true }
                else if ch == 0x7D {
                    braceDepth -= 1
                    if foundBrace && braceDepth == 0 { i += 1; break }
                }
                else if ch == 0x3B && braceDepth == 0 { i += 1; break } // ;
                // Skip strings
                else if ch == 0x27 || ch == 0x22 || ch == 0x60 {
                    let quote = ch
                    i += 1
                    while i < chars.count {
                        if chars[i] == 0x5C { i += 2; continue }
                        if chars[i] == quote { break }
                        i += 1
                    }
                }
                i += 1
            }

            var removeStart = match.range.location
            let matchStr = nsSource.substring(with: match.range)
            if matchStr.hasPrefix("\n") { removeStart += 1 }

            let removeRange = NSRange(location: removeStart, length: i - removeStart)
            let replacement = preserveNewlines(in: result as NSString, range: removeRange)
            result = (result as NSString).replacingCharacters(in: removeRange, with: replacement)
        }

        return result
    }

    // MARK: - Inline Type Removal

    private static func removeImplementsClause(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        // class Foo extends Bar implements Baz, Qux {  →  class Foo extends Bar {
        let regex = try! NSRegularExpression(
            pattern: #"\bimplements\s+[^{]+"#
        )
        return applyRegex(regex, to: source, excluded: excluded) { _, _ in "" }
    }

    private static func removeGenericTypeParameters(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // function name<T, U extends V>( → function name(
        // class Name<T> { → class Name {
        let regex = try! NSRegularExpression(
            pattern: #"((?:function\s*\*?\s*\w+|class\s+\w+)\s*)<"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let angleStart = match.range.location + match.range.length - 1 // position of `<`

            // Scan to matching `>`
            var depth = 1
            var i = angleStart + 1
            while i < chars.count && depth > 0 {
                if chars[i] == 0x3C { depth += 1 }
                else if chars[i] == 0x3E { depth -= 1 }
                else if chars[i] == 0x27 || chars[i] == 0x22 {
                    let q = chars[i]
                    i += 1
                    while i < chars.count && chars[i] != q {
                        if chars[i] == 0x5C { i += 1 }
                        i += 1
                    }
                }
                i += 1
            }

            let removeRange = NSRange(location: angleStart, length: i - angleStart)
            result = (result as NSString).replacingCharacters(in: removeRange, with: "")
        }

        return result
    }

    private static func removeAccessModifiers(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        // public/private/protected/abstract/override keyword followed by space
        // Must be at start of a class member declaration
        let regex = try! NSRegularExpression(
            pattern: #"(?<=^|[\n;{])\s*\K(?:public|private|protected|abstract|override)\s+"#
        )
        // NSRegularExpression doesn't support \K, use a different approach
        let regex2 = try! NSRegularExpression(
            pattern: #"(?:(?:^|\n|;|\{)\s*)((?:public|private|protected|abstract|override)\s+)"#
        )
        let nsSource = source as NSString
        let matches = regex2.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var result = source
        for match in matches.reversed() {
            let modRange = match.range(at: 1)
            if isInExcluded(modRange.location, excluded) { continue }
            result = (result as NSString).replacingCharacters(in: modRange, with: "")
        }
        return result
    }

    private static func removeReadonlyModifier(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        let regex = try! NSRegularExpression(pattern: #"\breadonly\s+"#)
        return applySimpleRegex(regex, to: source, excluded: excluded, replacement: "")
    }

    private static func removeDefiniteAssignment(_ source: String) -> String {
        let excluded = buildExcludedRanges(in: source)
        // identifier!: or identifier! = or identifier!; → remove the `!`
        let regex = try! NSRegularExpression(pattern: #"(\w)!\s*(?=[:=;,)\]])"#)
        return applySimpleRegex(regex, to: source, excluded: excluded, replacement: "$1")
    }

    private static func removeFunctionReturnTypes(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // ): Type { or ): Type => or ): Type;
        let regex = try! NSRegularExpression(pattern: #"\)\s*:\s*"#)
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let typeStart = match.range.location + match.range.length

            // Scan the type: terminators are { and =>
            // We use { as terminator. For =>, we check for = followed by >
            let typeEnd = scanTypeEnd(
                chars, from: typeStart,
                terminators: [0x7B, 0x3B] // { ;
            )

            // Check if we hit `=>` (arrow function)
            var actualEnd = typeEnd
            if actualEnd < chars.count && chars[actualEnd] == 0x7B {
                // Return type before function body — valid
            } else if actualEnd >= 2 {
                // Check for => pattern
            }

            // Also handle `=> {` case: scan for `=` that's part of `=>`
            let arrowEnd = findArrow(chars, from: typeStart, limit: typeEnd)
            if let ae = arrowEnd {
                actualEnd = ae
            }

            // Replace ): TYPE with just )
            let closeParenPos = match.range.location // position of )
            let replaceRange = NSRange(
                location: closeParenPos + 1,
                length: actualEnd - closeParenPos - 1
            )
            result = (result as NSString).replacingCharacters(in: replaceRange, with: "")
        }

        return result
    }

    /// Find the position of `=>` in the range [from, limit).
    /// Returns the position of `=` if found, nil otherwise.
    private static func findArrow(_ chars: [UInt16], from start: Int, limit: Int) -> Int? {
        var i = start
        var angleDepth = 0
        var parenDepth = 0
        var braceDepth = 0
        var bracketDepth = 0

        while i < limit && i + 1 < chars.count {
            let ch = chars[i]

            switch ch {
            case 0x3C: angleDepth += 1
            case 0x3E: if angleDepth > 0 { angleDepth -= 1 }
            case 0x28: parenDepth += 1
            case 0x29: if parenDepth > 0 { parenDepth -= 1 }
            case 0x7B: braceDepth += 1
            case 0x7D: if braceDepth > 0 { braceDepth -= 1 }
            case 0x5B: bracketDepth += 1
            case 0x5D: if bracketDepth > 0 { bracketDepth -= 1 }
            default: break
            }

            let depth = angleDepth + parenDepth + braceDepth + bracketDepth
            if depth == 0 && ch == 0x3D && chars[i + 1] == 0x3E { // =>
                return i
            }
            i += 1
        }
        return nil
    }

    private static func removeFunctionParamTypes(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)

        // Match `: TYPE` patterns inside function parameter lists.
        // We find function-like constructs and process their parameter lists.
        // Pattern: after identifier or `?`, a `:` followed by a type until `,` or `)` or `=`
        let regex = try! NSRegularExpression(
            pattern: #"(\w)\s*(\??)\s*:\s*(?=[^:,)=]*[,)=])"#
        )

        // Instead of the above (which is fragile), let's find all `:` that look like
        // parameter type annotations and remove the type.
        // Strategy: find `identifier?:` patterns where the identifier is preceded by
        // `(`, `,`, or whitespace in a param-like context.

        let colonRegex = try! NSRegularExpression(
            pattern: #"(\w)\s*(\?)\s*:\s*"#
        )
        let nsSource = result as NSString
        var colonMatches = colonRegex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        // Also match non-optional params: identifier followed by `:` where preceded by `(` or `,`
        let colonRegex2 = try! NSRegularExpression(
            pattern: #"(?<=[(,])\s*(?:\.\.\.)?(\w+)\s*:\s*"#
        )
        colonMatches += colonRegex2.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        // Deduplicate and sort by location descending
        var seen = Set<Int>()
        var uniqueMatches: [NSTextCheckingResult] = []
        for m in colonMatches {
            if seen.insert(m.range.location).inserted {
                uniqueMatches.append(m)
            }
        }
        uniqueMatches.sort { $0.range.location > $1.range.location }

        for match in uniqueMatches {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let afterColon = match.range.location + match.range.length

            // Find the colon position in the match
            let matchStr = (result as NSString).substring(with: match.range)
            guard let colonOffset = matchStr.lastIndex(of: ":") else { continue }
            let colonPos = match.range.location + matchStr.distance(from: matchStr.startIndex, to: colonOffset)

            // Verify this looks like a parameter (preceded by `(`, `,`, or param context)
            if !looksLikeParamType(Array(result.utf16), colonAt: colonPos) { continue }

            // Scan the type
            let typeEnd = scanTypeEnd(
                chars, from: afterColon,
                terminators: [0x2C, 0x29, 0x3D] // , ) =
            )

            // Check: is `?` present (optional param marker)?
            let hasQuestion = matchStr.contains("?")

            if hasQuestion {
                // Remove `?: TYPE` (keep identifier, remove `?` and `: TYPE`)
                let questionPos = match.range.location + matchStr.distance(
                    from: matchStr.startIndex,
                    to: matchStr.firstIndex(of: "?")!
                )
                // Find the identifier end (just before `?`)
                var identEnd = questionPos
                while identEnd > 0 && isWhitespace(chars[identEnd - 1]) { identEnd -= 1 }

                let removeRange = NSRange(location: identEnd, length: typeEnd - identEnd)
                result = (result as NSString).replacingCharacters(in: removeRange, with: "")
            } else {
                // Remove `: TYPE` part only
                let removeRange = NSRange(location: colonPos, length: typeEnd - colonPos)
                result = (result as NSString).replacingCharacters(in: removeRange, with: "")
            }
        }

        return result
    }

    /// Check if a `:` at the given position looks like a parameter type annotation.
    private static func looksLikeParamType(_ chars: [UInt16], colonAt pos: Int) -> Bool {
        // Walk backward from colon, skip whitespace and `?`
        var i = pos - 1
        while i >= 0 && (isWhitespace(chars[i]) || chars[i] == 0x3F) { i -= 1 } // skip ws and ?

        // Should be at end of an identifier
        guard i >= 0 && isIdentChar(chars[i]) else { return false }
        while i >= 0 && isIdentChar(chars[i]) { i -= 1 }

        // Skip `...` (rest param)
        if i >= 2 && chars[i] == 0x2E && chars[i-1] == 0x2E && chars[i-2] == 0x2E {
            i -= 3
        }

        // Skip whitespace
        while i >= 0 && isWhitespace(chars[i]) { i -= 1 }

        // Should be preceded by `(`, `,`, or start of line (for arrow function params)
        guard i >= 0 else { return false }
        return chars[i] == 0x28 || chars[i] == 0x2C // ( or ,
    }

    private static func removeVariableTypeAnnotations(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // const/let/var identifier: TYPE = ... or const/let/var identifier: TYPE;
        let regex = try! NSRegularExpression(
            pattern: #"((?:const|let|var)\s+\w+)\s*:\s*"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let typeStart = match.range.location + match.range.length

            // Scan type until `=` or `;` or newline at depth 0
            let typeEnd = scanTypeEnd(
                chars, from: typeStart,
                terminators: [0x3D, 0x3B, 0x0A] // = ; \n
            )

            // Replace "const x: TYPE" with "const x"
            let declEnd = match.range(at: 1).location + match.range(at: 1).length
            let removeRange = NSRange(location: declEnd, length: typeEnd - declEnd)
            // Add a space before `=` if the terminator is `=`
            let replacement: String
            if typeEnd < chars.count && chars[typeEnd] == 0x3D {
                replacement = " "
            } else {
                replacement = ""
            }
            result = (result as NSString).replacingCharacters(in: removeRange, with: replacement)
        }

        return result
    }

    private static func removeAsAssertions(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        // expr as Type — word boundary before `as`, not `as` in identifier
        let regex = try! NSRegularExpression(
            pattern: #"\s+as\s+(?![\n;,)}\]=])"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let afterAs = match.range.location + match.range.length

            // Scan the type
            let typeEnd = scanTypeEnd(
                chars, from: afterAs,
                terminators: [0x2C, 0x29, 0x3B, 0x0A, 0x7D, 0x5D, 0x3D] // , ) ; \n } ] =
            )

            // Trim trailing whitespace from the type
            var actualEnd = typeEnd
            while actualEnd > afterAs && isWhitespace(chars[actualEnd - 1]) { actualEnd -= 1 }

            let removeRange = NSRange(location: match.range.location, length: actualEnd - match.range.location)
            result = (result as NSString).replacingCharacters(in: removeRange, with: "")
        }

        return result
    }

    private static func removeSatisfiesExpressions(_ source: String) -> String {
        var result = source
        let excluded = buildExcludedRanges(in: result)
        let regex = try! NSRegularExpression(
            pattern: #"\s+satisfies\s+"#
        )
        let nsSource = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsSource.length))

        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            let chars = Array(result.utf16)
            let afterSatisfies = match.range.location + match.range.length

            let typeEnd = scanTypeEnd(
                chars, from: afterSatisfies,
                terminators: [0x2C, 0x29, 0x3B, 0x0A, 0x7D, 0x5D] // , ) ; \n } ]
            )

            var actualEnd = typeEnd
            while actualEnd > afterSatisfies && isWhitespace(chars[actualEnd - 1]) { actualEnd -= 1 }

            let removeRange = NSRange(location: match.range.location, length: actualEnd - match.range.location)
            result = (result as NSString).replacingCharacters(in: removeRange, with: "")
        }

        return result
    }

    private static func removeOptionalParamMarker(_ source: String) -> String {
        // Remove leftover `?` before `,` or `)` in function params
        // This handles cases where param types were already stripped: `x? ,` → `x,`
        let excluded = buildExcludedRanges(in: source)
        let regex = try! NSRegularExpression(
            pattern: #"(\w)\?\s*(?=[,)])"#
        )
        return applySimpleRegex(regex, to: source, excluded: excluded, replacement: "$1")
    }

    // MARK: - Line Preservation

    /// Return a string containing only the newline characters from the given range,
    /// so that line numbers in error messages are preserved after stripping.
    private static func preserveNewlines(in source: NSString, range: NSRange) -> String {
        let text = source.substring(with: range)
        var newlines = ""
        for ch in text {
            if ch == "\n" { newlines.append("\n") }
        }
        return newlines
    }

    /// Count newlines in a UTF-16 character array within a range.
    private static func countNewlines(_ chars: [UInt16], from: Int, to: Int) -> Int {
        var count = 0
        for i in from..<min(to, chars.count) {
            if chars[i] == 0x0A { count += 1 }
        }
        return count
    }

    /// Create a string of `n` newlines.
    private static func newlines(_ n: Int) -> String {
        String(repeating: "\n", count: n)
    }

    // MARK: - Helpers

    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D
    }

    private static func isIdentChar(_ ch: UInt16) -> Bool {
        (ch >= 0x61 && ch <= 0x7A) || (ch >= 0x41 && ch <= 0x5A)
            || (ch >= 0x30 && ch <= 0x39) || ch == 0x5F || ch == 0x24
    }

    /// Remove all regex matches (that are not in excluded ranges) from the source.
    /// Preserves newlines within the removed range to maintain line numbers.
    private static func removeMatches(
        _ regex: NSRegularExpression,
        in source: String,
        excluded: [ExcludedRange]
    ) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var result = source
        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }

            var removeRange = match.range
            let matchStr = nsSource.substring(with: match.range)
            if matchStr.hasPrefix("\n") {
                removeRange = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            }
            let replacement = preserveNewlines(in: result as NSString, range: removeRange)
            result = (result as NSString).replacingCharacters(in: removeRange, with: replacement)
        }
        return result
    }

    /// Apply a regex transformation, skipping matches in excluded ranges.
    private static func applyRegex(
        _ regex: NSRegularExpression,
        to source: String,
        excluded: [ExcludedRange],
        transformer: (String, NSTextCheckingResult) -> String
    ) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var result = source
        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }
            let replacement = transformer(result, match)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    /// Apply a regex with a template replacement string, skipping excluded ranges.
    private static func applySimpleRegex(
        _ regex: NSRegularExpression,
        to source: String,
        excluded: [ExcludedRange],
        replacement: String
    ) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        var result = source
        for match in matches.reversed() {
            if isInExcluded(match.range.location, excluded) { continue }
            let replaced = regex.replacementString(for: match, in: result, offset: 0, template: replacement)
            result = (result as NSString).replacingCharacters(in: match.range, with: replaced)
        }
        return result
    }
}

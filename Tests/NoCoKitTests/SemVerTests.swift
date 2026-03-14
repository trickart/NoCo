import Testing
@testable import NoCoKit

@Suite("SemVer Tests")
struct SemVerTests {

    // MARK: - Parsing

    @Test("Parse basic version")
    func parseBasic() {
        let v = SemVer("1.2.3")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
        #expect(v?.prerelease.isEmpty == true)
    }

    @Test("Parse version with v prefix")
    func parseWithPrefix() {
        let v = SemVer("v1.0.0")
        #expect(v != nil)
        #expect(v?.major == 1)
    }

    @Test("Parse version with prerelease")
    func parsePrerelease() {
        let v = SemVer("1.0.0-beta.1")
        #expect(v != nil)
        #expect(v?.prerelease == ["beta", "1"])
    }

    @Test("Parse version with build metadata")
    func parseBuildMetadata() {
        let v = SemVer("1.0.0+build.123")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.prerelease.isEmpty == true)
    }

    @Test("Parse version with prerelease and build metadata")
    func parsePrereleaseAndBuild() {
        let v = SemVer("1.0.0-alpha.1+build")
        #expect(v != nil)
        #expect(v?.prerelease == ["alpha", "1"])
    }

    @Test("Invalid version strings")
    func parseInvalid() {
        #expect(SemVer("abc") == nil)
        #expect(SemVer("1.2") == nil)
        #expect(SemVer("") == nil)
    }

    // MARK: - Comparison

    @Test("Version ordering")
    func comparison() {
        #expect(SemVer("1.0.0")! < SemVer("2.0.0")!)
        #expect(SemVer("1.0.0")! < SemVer("1.1.0")!)
        #expect(SemVer("1.0.0")! < SemVer("1.0.1")!)
        #expect(SemVer("1.0.0")! == SemVer("1.0.0")!)
    }

    @Test("Prerelease has lower precedence")
    func prereleaseOrdering() {
        #expect(SemVer("1.0.0-alpha")! < SemVer("1.0.0")!)
        #expect(SemVer("1.0.0-alpha")! < SemVer("1.0.0-beta")!)
        #expect(SemVer("1.0.0-alpha.1")! < SemVer("1.0.0-alpha.2")!)
    }

    // MARK: - Ranges

    @Test("Caret range")
    func caretRange() {
        let range = SemVerRange("^1.2.3")!
        #expect(range.satisfiedBy(SemVer("1.2.3")!))
        #expect(range.satisfiedBy(SemVer("1.9.9")!))
        #expect(!range.satisfiedBy(SemVer("2.0.0")!))
        #expect(!range.satisfiedBy(SemVer("1.2.2")!))
    }

    @Test("Caret range with zero major")
    func caretRangeZeroMajor() {
        let range = SemVerRange("^0.2.3")!
        #expect(range.satisfiedBy(SemVer("0.2.3")!))
        #expect(range.satisfiedBy(SemVer("0.2.9")!))
        #expect(!range.satisfiedBy(SemVer("0.3.0")!))
    }

    @Test("Tilde range")
    func tildeRange() {
        let range = SemVerRange("~1.2.3")!
        #expect(range.satisfiedBy(SemVer("1.2.3")!))
        #expect(range.satisfiedBy(SemVer("1.2.9")!))
        #expect(!range.satisfiedBy(SemVer("1.3.0")!))
    }

    @Test("Exact version")
    func exactVersion() {
        let range = SemVerRange("1.2.3")!
        #expect(range.satisfiedBy(SemVer("1.2.3")!))
        #expect(!range.satisfiedBy(SemVer("1.2.4")!))
    }

    @Test("Comparison operators")
    func comparisonOperators() {
        let range = SemVerRange(">=1.0.0 <2.0.0")!
        #expect(range.satisfiedBy(SemVer("1.0.0")!))
        #expect(range.satisfiedBy(SemVer("1.5.0")!))
        #expect(!range.satisfiedBy(SemVer("2.0.0")!))
        #expect(!range.satisfiedBy(SemVer("0.9.9")!))
    }

    @Test("OR ranges")
    func orRanges() {
        let range = SemVerRange("^1.0.0 || ^2.0.0")!
        #expect(range.satisfiedBy(SemVer("1.5.0")!))
        #expect(range.satisfiedBy(SemVer("2.5.0")!))
        #expect(!range.satisfiedBy(SemVer("3.0.0")!))
    }

    @Test("Wildcard range")
    func wildcardRange() {
        let range = SemVerRange("*")!
        #expect(range.satisfiedBy(SemVer("1.0.0")!))
        #expect(range.satisfiedBy(SemVer("99.99.99")!))
    }

    @Test("X-range")
    func xRange() {
        let range = SemVerRange("1.x")!
        #expect(range.satisfiedBy(SemVer("1.0.0")!))
        #expect(range.satisfiedBy(SemVer("1.9.9")!))
        #expect(!range.satisfiedBy(SemVer("2.0.0")!))
    }

    @Test("Hyphen range")
    func hyphenRange() {
        let range = SemVerRange("1.0.0 - 2.0.0")!
        #expect(range.satisfiedBy(SemVer("1.0.0")!))
        #expect(range.satisfiedBy(SemVer("1.5.0")!))
        #expect(range.satisfiedBy(SemVer("2.0.0")!))
        #expect(!range.satisfiedBy(SemVer("2.0.1")!))
    }

    @Test("Best match")
    func bestMatch() {
        let range = SemVerRange("^1.0.0")!
        let versions = [
            SemVer("1.0.0")!, SemVer("1.1.0")!, SemVer("1.2.0")!,
            SemVer("2.0.0")!, SemVer("0.9.0")!
        ]
        let best = range.bestMatch(from: versions)
        #expect(best == SemVer("1.2.0")!)
    }

    @Test("Description")
    func description() {
        #expect(SemVer("1.2.3")!.description == "1.2.3")
        #expect(SemVer("1.0.0-beta.1")!.description == "1.0.0-beta.1")
    }
}

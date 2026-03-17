import Foundation
import Testing
@testable import NoCoKit

@Test func transformPrettyFormatExport() async throws {
    let src = try String(contentsOfFile: "/Users/trick/NoCo/node_modules/@vitest/pretty-format/dist/index.js", encoding: .utf8)
    let result = ESMTransformer.transform(src)
    // The final export statement must be transformed
    #expect(!result.contains("export { DEFAULT_OPTIONS"))
    #expect(result.contains("__esm_export(module, 'format'"))
}

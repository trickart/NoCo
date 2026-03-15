import Foundation
import Testing
@testable import NoCoKit

// MARK: - Import Transformations

@Test func transformDefaultImport() async throws {
    let source = "import foo from 'bar';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('bar', __noco_dirname__)"))
    #expect(result.contains("foo = __m.default"))
}

@Test func transformNamedImport() async throws {
    let source = "import { readFile, writeFile } from 'fs';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('fs', __noco_dirname__)"))
    #expect(result.contains("readFile"))
    #expect(result.contains("writeFile"))
}

@Test func transformNamedImportWithAlias() async throws {
    let source = "import { readFile as rf } from 'fs';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("readFile: rf"))
}

@Test func transformNamespaceImport() async throws {
    let source = "import * as fs from 'fs';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("var fs = __esm_import('fs', __noco_dirname__)"))
}

@Test func transformSideEffectImport() async throws {
    let source = "import './polyfill';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('./polyfill', __noco_dirname__)"))
}

@Test func transformMixedImport() async throws {
    let source = "import def, { named } from 'mod';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('mod', __noco_dirname__)"))
    #expect(result.contains("def = __m.default"))
    #expect(result.contains("named"))
}

// MARK: - Export Transformations

@Test func transformExportConst() async throws {
    let source = "export const x = 42;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("const x = 42"))
    #expect(result.contains("__esm_export(module, 'x', function() { return x; })"))
}

@Test func transformExportLet() async throws {
    let source = "export let count = 0;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("let count = 0"))
    #expect(result.contains("__esm_export(module, 'count', function() { return count; })"))
}

@Test func transformExportFunction() async throws {
    let source = "export function greet() { return 'hi'; }"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("function greet()"))
    #expect(result.contains("__esm_export(module, 'greet', function() { return greet; })"))
}

@Test func transformExportClass() async throws {
    let source = "export class Foo {}"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("class Foo {}"))
    #expect(result.contains("__esm_export(module, 'Foo', function() { return Foo; })"))
}

@Test func transformExportDefault() async throws {
    let source = "export default 42;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export_default(module, 42)"))
}

@Test func transformExportDefaultFunction() async throws {
    let source = "export default function greet() { return 'hi'; }"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("function greet()"))
    #expect(result.contains("__esm_export_default(module, greet)"))
}

@Test func transformExportNamedList() async throws {
    let source = """
    const a = 1;
    const b = 2;
    export { a, b };
    """
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'a', function() { return a; })"))
    #expect(result.contains("__esm_export(module, 'b', function() { return b; })"))
}

@Test func transformExportNamedWithAlias() async throws {
    let source = """
    const internal = 1;
    export { internal as external };
    """
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'external', function() { return internal; })"))
}

@Test func transformReExportNamed() async throws {
    let source = "export { foo } from 'bar';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('bar', __noco_dirname__)"))
    #expect(result.contains("__esm_export(module, 'foo'"))
}

@Test func transformReExportAll() async throws {
    let source = "export * from 'bar';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export_star(module, __esm_import('bar', __noco_dirname__))"))
}

// MARK: - Minified (no space) patterns

@Test func transformMinifiedNamedImport() async throws {
    let source = "import{a}from'b';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('b', __noco_dirname__)"))
    #expect(result.contains("a"))
}

@Test func transformMinifiedNamespaceImport() async throws {
    let source = "import*as ns from'mod';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("var ns = __esm_import('mod', __noco_dirname__)"))
}

@Test func transformMinifiedSideEffectImport() async throws {
    let source = "import'./module';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('./module', __noco_dirname__)"))
}

@Test func transformMinifiedExportNamedList() async throws {
    let source = "const a = 1;const b = 2;\nexport{a as x,b as y};"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'x', function() { return a; })"))
    #expect(result.contains("__esm_export(module, 'y', function() { return b; })"))
}

@Test func transformMinifiedReExportAll() async throws {
    let source = "export*from'module';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export_star(module, __esm_import('module', __noco_dirname__))"))
}

@Test func transformMinifiedReExportNamed() async throws {
    let source = "export{foo}from'bar';"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_import('bar', __noco_dirname__)"))
    #expect(result.contains("__esm_export(module, 'foo'"))
}

// MARK: - import.meta

@Test func transformImportMeta() async throws {
    let source = "console.log(import.meta.url);"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
    #expect(result.contains("var import_meta = Object.freeze("))
}

// MARK: - Dynamic import()

@Test func transformDynamicImport() async throws {
    let source = "const m = import('./foo');"
    let result = ESMTransformer.transformDynamicImport(source)
    #expect(result.contains("__importDynamic('./foo', __dirname)"))
}

@Test func transformDynamicImportDoesNotMatchMethod() async throws {
    let source = "obj.import('foo');"
    let result = ESMTransformer.transformDynamicImport(source)
    #expect(!result.contains("__importDynamic"))
}

// MARK: - Comment/String Exclusion

@Test func ignoreImportInComment() async throws {
    let source = """
    // import { foo } from 'bar';
    const x = 1;
    """
    let result = ESMTransformer.transform(source)
    #expect(!result.contains("__esm_import('bar'"))
}

@Test func ignoreImportInString() async throws {
    let source = """
    const s = "import { foo } from 'bar'";
    """
    let result = ESMTransformer.transform(source)
    #expect(!result.contains("__esm_import('bar'"))
}

@Test func ignoreImportInMultilineComment() async throws {
    let source = """
    /* import { foo } from 'bar'; */
    const x = 1;
    """
    let result = ESMTransformer.transform(source)
    #expect(!result.contains("__esm_import('bar'"))
}

// MARK: - __esModule marker

@Test func addsEsModuleMarker() async throws {
    let source = "export const x = 1;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("Object.defineProperty(module.exports, '__esModule', {value: true})"))
}

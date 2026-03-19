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

// MARK: - Template Literal Nesting

@Test func ignoreImportInTemplateLiteral() async throws {
    let source = "const s = `import { foo } from 'bar'`;"
    let result = ESMTransformer.transform(source)
    #expect(!result.contains("__esm_import('bar'"))
}

@Test func transformImportMetaInTemplateExpression() async throws {
    let source = "const s = `url: ${import.meta.url}`;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
}

@Test func transformImportMetaInNestedTemplate() async throws {
    let source = "const s = `outer ${`inner ${import.meta.url}`}`;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
}

@Test func transformImportMetaAfterNestedTemplate() async throws {
    let source = "const s = `${`nested`}`;\nconsole.log(import.meta.url);"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
}

@Test func transformMultipleExpressionsWithImportMeta() async throws {
    let source = "const s = `${import.meta.url} and ${import.meta.dirname}`;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
    #expect(result.contains("import_meta.dirname"))
}

@Test func templateExpressionWithBraceInString() async throws {
    let source = #"const s = `${"}"} ${import.meta.url}`;"#
    let result = ESMTransformer.transform(source)
    #expect(result.contains("import_meta.url"))
}

// MARK: - Minified export const/let/var on same line

@Test func transformMultipleExportVarOnSameLine() async throws {
    let source = "export var Foo = 42; export const bar = 1;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'Foo', function() { return Foo; })"))
    #expect(result.contains("__esm_export(module, 'bar', function() { return bar; })"))
    #expect(!result.contains("export var"))
    #expect(!result.contains("export const"))
}

@Test func transformMultipleExportOnSameLineSemicolonSeparated() async throws {
    let source = "export const a = 1;export let b = 2;export var c = 3;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'a', function() { return a; })"))
    #expect(result.contains("__esm_export(module, 'b', function() { return b; })"))
    #expect(result.contains("__esm_export(module, 'c', function() { return c; })"))
}

@Test func transformExportConstWithComplexExpression() async throws {
    // export const with a function call containing parentheses
    let source = "export const init = WebAssembly.compile(E()).then(f); export const parse = doSomething();"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'init', function() { return init; })"))
    #expect(result.contains("__esm_export(module, 'parse', function() { return parse; })"))
}

@Test func transformExportVarWithIIFE() async throws {
    // export var followed by IIFE (like es-module-lexer's ImportType pattern)
    let source = "export var ImportType;!function(A){A[A.Static=1]=\"Static\"}(ImportType||(ImportType={})); export const foo = 1;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'ImportType', function() { return ImportType; })"))
    #expect(result.contains("__esm_export(module, 'foo', function() { return foo; })"))
}

@Test func transformExportConstWithNestedBrackets() async throws {
    let source = "export const obj = {a: [1, 2], b: {c: 3}}; export const x = 1;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("__esm_export(module, 'obj', function() { return obj; })"))
    #expect(result.contains("__esm_export(module, 'x', function() { return x; })"))
}

// MARK: - __esModule marker

@Test func addsEsModuleMarker() async throws {
    let source = "export const x = 1;"
    let result = ESMTransformer.transform(source)
    #expect(result.contains("Object.defineProperty(module.exports, '__esModule', {value: true})"))
}

// MARK: - Top-Level Await Detection

@Test func detectTopLevelAwait() async throws {
    let source = "const x = await fetch('/api');"
    #expect(ESMTransformer.containsTopLevelAwait(source) == true)
}

@Test func detectTopLevelAwaitWithDynamicImport() async throws {
    let source = "const m = await import('./foo.mjs');"
    #expect(ESMTransformer.containsTopLevelAwait(source) == true)
}

@Test func noTopLevelAwaitInsideFunction() async throws {
    let source = "async function f() { await p; }"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func noTopLevelAwaitInsideArrow() async throws {
    let source = "const f = async () => { await p; };"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func noTopLevelAwaitInsideMethod() async throws {
    let source = "class Foo { async bar() { await p; } }"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func awaitInStringIsNotTLA() async throws {
    let source = "const s = 'await something';"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func awaitInCommentIsNotTLA() async throws {
    let source = "// await something\nconst x = 1;"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func forAwaitIsTopLevel() async throws {
    let source = "for await (const x of stream) { console.log(x); }"
    #expect(ESMTransformer.containsTopLevelAwait(source) == true)
}

@Test func noAwaitAtAll() async throws {
    let source = "const x = 1;\nconsole.log(x);"
    #expect(ESMTransformer.containsTopLevelAwait(source) == false)
}

@Test func awaitInsideControlFlowIsTopLevel() async throws {
    // if/for/while braces don't create function scope — TLA is valid inside them
    let source = "if (true) { const x = await fetch('/api'); }"
    #expect(ESMTransformer.containsTopLevelAwait(source) == true)
}

@Test func awaitAfterFunctionIsTopLevel() async throws {
    let source = "function f() { return 1; }\nconst x = await Promise.resolve(42);"
    #expect(ESMTransformer.containsTopLevelAwait(source) == true)
}

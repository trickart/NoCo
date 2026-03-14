import Testing
@testable import NoCoKit

struct TypeScriptStripperTests {

    // MARK: - Type Annotations

    @Test func stripVariableTypeAnnotation() {
        let input = #"const x: string = "hello";"#
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains(#"const x = "hello";"#))
        #expect(!result.contains(": string"))
    }

    @Test func stripLetTypeAnnotation() {
        let input = "let count: number = 42;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("let count = 42;"))
    }

    @Test func stripVarTypeAnnotationWithoutInit() {
        let input = "let x: number;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("let x;"))
        #expect(!result.contains(": number"))
    }

    // MARK: - Function Types

    @Test func stripFunctionParamTypes() {
        let input = "function greet(name: string, age: number) { return name; }"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("function greet(name, age)"))
        #expect(!result.contains(": string"))
        #expect(!result.contains(": number"))
    }

    @Test func stripFunctionReturnType() {
        let input = "function add(a: number, b: number): number { return a + b; }"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("function add(a, b)"))
        #expect(result.contains("{ return a + b; }"))
    }

    @Test func stripGenericTypeParameters() {
        let input = "function identity<T>(x: T): T { return x; }"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("function identity(x)"))
        #expect(!result.contains("<T>"))
    }

    @Test func stripOptionalParameter() {
        let input = "function f(x?: string) { return x; }"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("function f(x)"))
        #expect(!result.contains("?"))
    }

    @Test func stripRestParameterType() {
        let input = "function f(...args: string[]) { return args; }"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("...args"))
        #expect(!result.contains(": string[]"))
    }

    // MARK: - Interface / Type / Declare

    @Test func removeInterfaceDeclaration() {
        let input = """
        interface User {
            name: string;
            age: number;
        }
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("interface"))
        #expect(!result.contains("name: string"))
        #expect(result.contains("const x = 1;"))
    }

    @Test func removeTypeAlias() {
        let input = """
        type StringOrNumber = string | number;
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("type StringOrNumber"))
        #expect(result.contains("const x = 1;"))
    }

    @Test func removeImportType() {
        let input = """
        import type { Foo } from './foo';
        import { bar } from './bar';
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("import type"))
        #expect(result.contains("import { bar } from './bar';"))
    }

    @Test func removeExportType() {
        let input = """
        export type { Foo } from './foo';
        export { bar } from './bar';
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("export type"))
        #expect(result.contains("export { bar } from './bar';"))
    }

    @Test func removeDeclareStatement() {
        let input = """
        declare const MY_VAR: string;
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("declare"))
        #expect(result.contains("const x = 1;"))
    }

    @Test func removeDeclareModule() {
        let input = """
        declare module 'foo' {
            export function bar(): void;
        }
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("declare module"))
        #expect(result.contains("const x = 1;"))
    }

    // MARK: - Type Assertions

    @Test func stripAsAssertion() {
        let input = "const y = x as string;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("const y = x;"))
        #expect(!result.contains("as string"))
    }

    @Test func stripSatisfiesExpression() {
        let input = "const config = {} satisfies Config;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("const config = {};"))
        #expect(!result.contains("satisfies"))
    }

    // MARK: - Access Modifiers

    @Test func stripAccessModifiers() {
        let input = """
        class Foo {
        public name = "test";
        private age = 30;
        protected id = 1;
        }
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("public "))
        #expect(!result.contains("private "))
        #expect(!result.contains("protected "))
        #expect(result.contains("name = \"test\""))
    }

    @Test func stripReadonly() {
        let input = "readonly name = 'test';"
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("readonly"))
        #expect(result.contains("name = 'test';"))
    }

    // MARK: - Implements Clause

    @Test func stripImplementsClause() {
        let input = "class Foo extends Bar implements Baz, Qux {"
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("implements"))
        #expect(result.contains("class Foo extends Bar"))
        #expect(result.contains("{"))
    }

    // MARK: - Definite Assignment

    @Test func stripDefiniteAssignment() {
        let input = "let x!: string;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("let x;"))
        #expect(!result.contains("!"))
    }

    // MARK: - String Literal Preservation

    @Test func preserveTypeInStringLiteral() {
        let input = #"const s = "x: string";"#
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains(#""x: string""#))
    }

    @Test func preserveTypeInTemplateLiteral() {
        let input = "const s = `type: ${value}`;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("`type: ${value}`"))
    }

    // MARK: - Complex Types

    @Test func stripGenericVariableType() {
        let input = "const map: Map<string, number> = new Map();"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("const map = new Map();"))
    }

    @Test func stripUnionType() {
        let input = "let val: string | number = 42;"
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("let val = 42;"))
    }

    @Test func removeExportedInterface() {
        let input = """
        export interface Config {
            host: string;
            port: number;
        }
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("interface"))
        #expect(result.contains("const x = 1;"))
    }

    @Test func removeExportedTypeAlias() {
        let input = """
        export type ID = string | number;
        const x = 1;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("type ID"))
        #expect(result.contains("const x = 1;"))
    }

    @Test func removeImportTypeDefault() {
        let input = "import type Foo from './foo';"
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("import type"))
    }

    @Test func removeImportTypeNamespace() {
        let input = "import type * as Types from './types';"
        let result = TypeScriptStripper.strip(input)
        #expect(!result.contains("import type"))
    }

    // MARK: - Integration: Excluded Ranges

    @Test func typeInCommentIsPreserved() {
        let input = """
        // const x: string = "hello";
        const y = 42;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("// const x: string"))
        #expect(result.contains("const y = 42;"))
    }

    @Test func typeInMultilineCommentIsPreserved() {
        let input = """
        /* interface Foo {
            bar: string;
        } */
        const y = 42;
        """
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("/* interface Foo"))
        #expect(result.contains("const y = 42;"))
    }

    // MARK: - Line Number Preservation

    @Test func preserveLineNumbers() {
        let source = "// line 1\ninterface Foo {\n    bar: string;\n    baz: number;\n}\n// line 6\nfunction greet(name: string): void {\n    console.log(name);\n}\n// line 10"
        let stripped = TypeScriptStripper.strip(source)
        let originalCount = source.components(separatedBy: "\n").count
        let strippedCount = stripped.components(separatedBy: "\n").count
        #expect(originalCount == strippedCount, "Line count mismatch: original=\(originalCount) stripped=\(strippedCount)\nStripped:\n\(stripped)")
    }

    @Test func preserveLineNumbersMultiLineType() {
        let source = "const x = 1;\ntype Complex = {\n    a: string;\n    b: number;\n};\nconst y = 2;"
        let stripped = TypeScriptStripper.strip(source)
        let originalCount = source.components(separatedBy: "\n").count
        let strippedCount = stripped.components(separatedBy: "\n").count
        #expect(originalCount == strippedCount, "Line count mismatch: original=\(originalCount) stripped=\(strippedCount)\nStripped:\n\(stripped)")
    }

    @Test func preserveLineNumbersDeclareBlock() {
        let source = "const a = 1;\ndeclare module 'foo' {\n    export function bar(): void;\n}\nconst b = 2;"
        let stripped = TypeScriptStripper.strip(source)
        let originalCount = source.components(separatedBy: "\n").count
        let strippedCount = stripped.components(separatedBy: "\n").count
        #expect(originalCount == strippedCount, "Line count mismatch: original=\(originalCount) stripped=\(strippedCount)\nStripped:\n\(stripped)")
    }

    // MARK: - Multiline Class with Generic

    @Test func stripClassWithGeneric() {
        let input = """
        class Container<T> {
            constructor(value) {
                this.value = value;
            }
        }
        """
        let result = TypeScriptStripper.strip(input)
        #expect(result.contains("class Container {"))
        #expect(!result.contains("<T>"))
    }
}

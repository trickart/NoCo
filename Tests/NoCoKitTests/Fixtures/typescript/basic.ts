// Basic TypeScript file for testing type stripping
interface Greeter {
    name: string;
    greet(): string;
}

type ID = string | number;

function greet(name: string, greeting?: string): string {
    const msg: string = greeting || "Hello";
    return msg + ", " + name + "!";
}

const result: string = greet("World");
console.log(result);

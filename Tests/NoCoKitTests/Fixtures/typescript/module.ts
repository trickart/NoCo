// TypeScript module for require() testing
interface MathOps {
    add(a: number, b: number): number;
    multiply(a: number, b: number): number;
}

function add(a: number, b: number): number {
    return a + b;
}

function multiply(a: number, b: number): number {
    return a * b;
}

const PI: number = 3.14159;

module.exports = { add, multiply, PI };

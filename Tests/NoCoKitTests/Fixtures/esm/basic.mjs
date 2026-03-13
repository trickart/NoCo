import { join } from 'path';

export const greeting = 'hello';
export function add(a, b) { return a + b; }

const result = join('a', 'b');
console.log('basic:' + greeting + ':' + result);

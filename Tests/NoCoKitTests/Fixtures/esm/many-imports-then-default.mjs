import { a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16 } from './many-named-exports.mjs';
import path from 'node:path';
console.log('many-imports:' + a1 + ':' + a16 + ':' + typeof path.join);

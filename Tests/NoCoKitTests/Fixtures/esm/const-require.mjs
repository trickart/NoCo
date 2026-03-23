// ESM file that redefines `require` using createRequire (common bundler pattern)
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const path = require('path');
console.log("const-require:" + path.join('a', 'b'));

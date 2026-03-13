import cjs from './cjs-module.cjs';
import { foo } from './cjs-module.cjs';
console.log('default:' + cjs.foo);
console.log('named:' + foo);

import { count, increment } from './live-binding.mjs';
console.log('before:' + count);
increment();
console.log('after:' + count);

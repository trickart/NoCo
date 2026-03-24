// Test: new Function() 内の import() が __importDynamic() に変換されるか
const importESM = new Function('specifier', 'return import(specifier)');
const path = require('path');
const target = path.join(__dirname, 'basic.mjs');

importESM(target).then(function(m) {
    console.log('new-function-import:' + m.greeting);
}).catch(function(e) {
    console.log('new-function-import:error:' + e.message);
});

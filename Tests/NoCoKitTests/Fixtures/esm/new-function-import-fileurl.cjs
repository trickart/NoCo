// Test: new Function() 内の import() が file:// URL でも動くか
const { pathToFileURL } = require('url');
const path = require('path');
const importESM = new Function('specifier', 'return import(specifier)');
const target = pathToFileURL(path.join(__dirname, 'basic.mjs')).href;

importESM(target).then(function(m) {
    console.log('new-function-fileurl:' + m.greeting);
}).catch(function(e) {
    console.log('new-function-fileurl:error:' + e.message);
});

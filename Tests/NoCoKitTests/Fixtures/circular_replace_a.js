var a_exports = {};
Object.defineProperty(a_exports, 'getValue', {
    get: function() { return getValue; },
    enumerable: true
});
module.exports = a_exports;
var b = require('./circular_replace_b');
function getValue() { return 'fromA'; }

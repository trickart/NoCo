// Circular dependency test: a requires b
exports.fromA = 'valueA';
var b = require('./circular_b');
exports.fromB = b.fromB;

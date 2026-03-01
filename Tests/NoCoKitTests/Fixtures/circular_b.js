// Circular dependency test: b requires a
var a = require('./circular_a');
exports.fromB = 'valueB';
exports.seenFromA = a.fromA;

var a = require('./circular_replace_a');
exports.getValueFromA = function() { return a.getValue(); };
exports.aHasGetValue = typeof a.getValue === 'function';

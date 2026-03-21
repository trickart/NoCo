// Send an object with circular references via IPC
var obj = { name: 'test', tasks: [] };
var task = { id: 1, parent: obj };
obj.tasks.push(task);
process.send(obj);
process.disconnect();

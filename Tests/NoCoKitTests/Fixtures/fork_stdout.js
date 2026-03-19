console.log("hello from child stdout");
process.send({ done: true });

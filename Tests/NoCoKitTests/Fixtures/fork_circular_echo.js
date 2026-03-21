// Echo back received messages (including circular references)
process.on('message', function(msg) {
    process.send(msg);
});

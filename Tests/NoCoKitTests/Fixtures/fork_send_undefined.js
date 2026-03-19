// Send undefined (JSON.stringify returns undefined for this)
process.send(undefined);
// Then send a valid message so the parent knows the child survived
process.send({ ok: true });
process.disconnect();

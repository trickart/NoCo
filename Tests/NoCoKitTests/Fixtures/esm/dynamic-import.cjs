async function main() {
    const m = await import('./basic.mjs');
    console.log('dynamic:' + m.greeting);
}
main();

(async () => {
  let installed;
  handlers.install({waitUntil(promise) {installed = promise;}});
  await installed;
  assert(![...entries.keys()].some(key => /\.(wasm|js)$/.test(key)));
  // Seed the unversioned entry left by the previous worker's install.
  await cache.put({url: origin + '/heronin/web.wasm'}, response('legacy'));
  await get('/heronin/web.wasm?build=one');
  await get('/heronin/other.wasm?build=one');
  await get('/heronin/web.wasm?build=two');
  const wasm = [...entries.keys()].filter(key => new URL(key).pathname === '/heronin/web.wasm');
  assert(wasm.length === 1 && wasm[0].endsWith('?build=two'));
  assert(entries.has(origin + '/heronin/other.wasm?build=one'));
  offline = true;
  assert((await get('/heronin/web.wasm?build=two')).ok);
  assert((await get('/heronin/deep-link', 'navigate')).ok);
  entries.delete(origin + '/heronin/');
  assert((await get('/heronin/', 'navigate')).ok);
  globalThis.passed = true;
})().catch(error => { globalThis.failure = String(error); });

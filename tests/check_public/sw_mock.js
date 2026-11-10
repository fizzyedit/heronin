const origin = 'https://example.test';
class URL {
  constructor(value) {
    const full = value.startsWith('/') ? origin + value : value;
    const match = /^(https?:\/\/[^/]+)([^?]*)(\?.*)?$/.exec(full);
    this.origin = match[1]; this.pathname = match[2]; this.search = match[3] || '';
  }
}
const handlers = {};
const self = {location: {origin}, clients: {claim() {}},
  addEventListener(type, handler) { handlers[type] = handler; }};
const entries = new Map();
const keyOf = key => typeof key === 'string' ? origin + key : key.url;
const cache = {
  async put(key, response) { entries.set(keyOf(key), response); },
  async match(key) { return entries.get(keyOf(key)); },
  async keys() { return [...entries.keys()].map(url => ({url})); },
  async delete(key) { return entries.delete(keyOf(key)); },
  async addAll(keys) { for (const key of keys) await this.put(key, response(key)); }
};
const caches = {async open() {return cache;}, async keys() {return [];}};
const response = body => ({ok: true, body, clone() {return this;}});
let offline = false;
async function fetch(request) {
  if (offline) throw new Error('offline');
  return response(request.url);
}
const Response = {error() {return {ok: false};}};
function assert(value) { if (!value) throw new Error('assertion failed'); }
async function get(path, mode = 'cors') {
  let result;
  handlers.fetch({request: {url: origin + path, method: 'GET', mode},
    respondWith(promise) { result = promise; }});
  return await result;
}

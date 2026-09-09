// Self-check: mỗi lần đổi màn phải sinh ĐỦ CẶP screen_exited + screen_viewed,
// và cả hai mang đủ field theo contract mobile (core C++ tracker.cpp:210-231).
// Chạy: node test-screen-pair.mjs
import assert from 'node:assert';

const listeners = {};
globalThis.window = globalThis;
Object.assign(globalThis, {
  addEventListener(k, f) { (listeners[k] ||= []).push(f); },
  removeEventListener() {},
  location: { href: 'https://a.vn/home', pathname: '/home', search: '', hash: '' },
  innerWidth: 1280, innerHeight: 800,
  history: { pushState() {}, replaceState() {} },
  requestAnimationFrame: (f) => setTimeout(f, 0),
});
globalThis.document = {
  title: 'T', referrer: '', visibilityState: 'visible', readyState: 'complete',
  addEventListener() {}, removeEventListener() {},
  documentElement: { scrollHeight: 800 }, body: {}, cookie: '',
};
Object.defineProperty(globalThis, 'navigator', {
  value: { userAgent: 'ua', language: 'vi', onLine: true, sendBeacon: () => true },
  configurable: true,
});
globalThis.screen = { width: 1280, height: 800 };
globalThis.performance = { now: () => Date.now(), getEntriesByType: () => [] };
globalThis.localStorage = { _d: {}, getItem(k){return this._d[k]??null;},
  setItem(k,v){this._d[k]=String(v);}, removeItem(k){delete this._d[k];} };
globalThis.sessionStorage = globalThis.localStorage;
globalThis.XMLHttpRequest = class { open(){} send(){} setRequestHeader(){} addEventListener(){} };
globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => ({}) });

const { UniTrack } = await import('./dist/unitrack.esm.js');
const seen = [];
UniTrack.addProvider({ name: 'spy', init() {}, track(n, p) { seen.push({ n, p }); } });
UniTrack.initialize('k', { endpoint: '', verboseLogging: false, trackNetwork: false });

await new Promise((r) => setTimeout(r, 400));   // chờ initial screen chốt '/home'
assert.ok(seen.some((e) => e.n === 'screen_viewed'),
  `initial screen_viewed không bắn — thấy: ${seen.map((e) => e.n).join(', ')}`);
seen.length = 0;                       // bỏ qua event khởi động
UniTrack.setScreen('/product/table-02');

const names = seen.map((e) => e.n);
// Đổi màn = đóng màn cũ RỒI mở màn mới. Thiếu vế mở là bug thật đã gặp:
// portal chỉ thấy screen_exited, không bao giờ thấy screen_viewed đi cùng.
assert.ok(names.includes('screen_viewed'),
  `setScreen() không bắn screen_viewed — chỉ thấy: ${names.join(', ')}`);

const viewed = seen.find((e) => e.n === 'screen_viewed').p;
assert.equal(viewed.screen, '/product/table-02');
assert.equal(viewed.screen_name, '/product/table-02');
// Luồng chuyển màn: 3 tên cho cùng giá trị, parity core C++ tracker.cpp:228-230.
for (const f of ['from', 'from_screen', 'previous_screen_name']) {
  assert.equal(viewed[f], '/home', `screen_viewed.${f} sai`);
}

const exited = seen.find((e) => e.n === 'screen_exited')?.p;
assert.ok(exited, 'không có screen_exited');
assert.equal(exited.screen_name, '/home');
assert.equal(exited.is_exit_screen, 'false');   // đổi route ≠ rời hẳn
assert.equal(exited.reason, 'screen_change');

console.log('PASS — đổi màn sinh đủ cặp screen_exited + screen_viewed, đủ field mobile');
process.exit(0);

// Self-check: ranh giới phiên. session_ended phải nói VỀ phiên vừa đóng
// (session_id = phiên cũ, parity mobile project 8), và phải có session_started
// đi kèm nối phiên mới với phiên trước nó.
// Chạy: node test-session-boundary.mjs
import assert from 'node:assert';

const listeners = {};
globalThis.window = globalThis;
Object.assign(globalThis, {
  addEventListener(k, f) { (listeners[k] ||= []).push(f); }, removeEventListener() {},
  location: { href: 'https://a.vn/home', pathname: '/home', search: '', hash: '' },
  innerWidth: 1280, innerHeight: 800, history: { pushState() {}, replaceState() {} },
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
globalThis.performance = { now: () => Date.now(), getEntriesByType: () => [], markResourceTiming() {} };
globalThis.localStorage = { _d: {}, getItem(k){return this._d[k]??null;},
  setItem(k,v){this._d[k]=String(v);}, removeItem(k){delete this._d[k];} };
globalThis.sessionStorage = globalThis.localStorage;
globalThis.XMLHttpRequest = class { open(){} send(){} setRequestHeader(){} addEventListener(){} };
globalThis.fetch = async () => ({ ok: true, status: 200, json: async () => ({}) });

const { UniTrack } = await import('./dist/unitrack.esm.js');
const seen = [];
UniTrack.addProvider({ name: 'spy', init() {}, track(n, p) { seen.push({ n, p }); } });
UniTrack.initialize('k', { endpoint: '', verboseLogging: false, trackNetwork: false });

await new Promise((r) => setTimeout(r, 300));
// Phiên MỞ ĐẦU cũng phải có session_started. SessionManager dựng phiên này
// thẳng trong constructor, không đi qua rotate(), nên callback onRotate không
// chạy — nếu chỉ dựa vào onRotate thì phiên đầu mỗi lần vào site không bao giờ
// được đếm, chỉ phiên thứ 2 trở đi mới có (mobile đếm cả phiên đầu).
const dau = seen.find((e) => e.n === 'session_started');
assert.ok(dau, `phiên đầu không có session_started — chỉ thấy: ${seen.map((e) => e.n).join(', ')}`);
assert.equal(dau.p.entry_source, 'app_open');
assert.equal(dau.p.session_id, UniTrack.currentSessionId(), 'session_started phải thuộc phiên vừa mở');

const oldSid = UniTrack.currentSessionId();
const oldIdx = UniTrack.sessionIndex();
seen.length = 0;

UniTrack.reset();                       // logout → rotate
const newSid = UniTrack.currentSessionId();
assert.notEqual(newSid, oldSid, 'reset() không xoay session');

const ended = seen.find((e) => e.n === 'session_ended')?.p;
assert.ok(ended, 'không bắn session_ended');
// Event này NÓI VỀ phiên vừa đóng → session_id phải là phiên cũ, y như mobile.
// Nếu mang phiên mới thì group-by session đếm nhầm nó vào phiên kế tiếp.
assert.equal(ended.session_id, oldSid,
  `session_ended.session_id = phiên MỚI (${ended.session_id}) thay vì phiên vừa đóng (${oldSid})`);
assert.equal(ended.ended_session_id, oldSid);
assert.equal(ended.previous_session_id, oldSid, 'thiếu previous_session_id (tên mobile dùng)');
assert.equal(ended.reason, 'manual');

// Đóng sổ rồi phải mở sổ: mobile có cặp started/ended, web trước đây chỉ có ended.
const started = seen.find((e) => e.n === 'session_started')?.p;
assert.ok(started, 'không bắn session_started — không đếm được số phiên bắt đầu');
assert.equal(started.previous_session_id, oldSid, 'session_started không nối được với phiên trước');
assert.equal(started.session_id, newSid, 'session_started phải thuộc phiên mới');
assert.equal(Number(started.session_index), oldIdx + 1);

console.log('PASS — session_ended mang phiên cũ, session_started nối phiên mới với phiên trước');
process.exit(0);

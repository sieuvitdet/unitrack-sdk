// Self-check: user_context + rotate session quanh login/logout.
//   - chưa login → entity VẪN có mặt, user_id/user_name là chuỗi rỗng
//   - login      → hai field mang hash SHA-256, không phải giá trị thô
//   - logout     → session_id đổi (rotate), entity quay về rỗng
// Chạy: node test-user-context.mjs
import assert from 'node:assert';
import { webcrypto } from 'node:crypto';

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

const sent = [];
globalThis.fetch = async (u, o) => {
  if (String(u).includes('/tp2')) sent.push(JSON.parse(o.body));
  return { ok: true, status: 200, json: async () => ({}) };
};

const { UniTrack, SnowplowProvider } = await import('./dist/unitrack.esm.js');
const sp = new SnowplowProvider({
  endpoint: 'https://collector.test', appId: 'web', igluVendor: 'vn.fpt.ftel.snowplow',
  defaultVersion: '1-0-0',
  entities: { user_context: 'user_context', core_action: 'core_action' },
});
UniTrack.addProvider(sp);
UniTrack.initialize('k', { endpoint: '', verboseLogging: false, trackNetwork: false,
                           piiSalt: 'demo_salt_2026' });

const userCtx = async () => {
  sent.length = 0;
  await sp.flush();
  const ev = sent.at(-1)?.data?.at(-1);
  const co = JSON.parse(ev.co);
  return co.data.find((c) => c.schema.includes('/user_context/'))?.data;
};

// ── 1. Chưa login ──────────────────────────────────────────────────────
UniTrack.track('probe', { screen: '/home' });
let u = await userCtx();
assert.ok(u, 'chưa login mà entity user_context BIẾN MẤT — đội Data phải xử lý 2 dạng hàng');
assert.equal(u.user_id, '', `user_id phải rỗng, thấy: ${JSON.stringify(u.user_id)}`);
assert.equal(u.user_name, '', `user_name phải rỗng, thấy: ${JSON.stringify(u.user_name)}`);
// phone_number: mobile luôn gửi (1080/1080 trên project 8) → web phải có mặt.
assert.equal(u.phone_number, '', 'thiếu phone_number — user_context lệch cấu trúc mobile');

// ── 2. Login → hash ────────────────────────────────────────────────────
const sidBefore = UniTrack.currentSessionId();
const idxBefore = UniTrack.sessionIndex();
await UniTrack.identify('an.nguyen@example.com', { user_name: 'Nguyễn An', tier: 'vàng' });
UniTrack.track('login', {});
u = await userCtx();
assert.match(u.user_id,   /^[0-9a-f]{64}$/, `user_id chưa hash: ${u.user_id}`);
assert.match(u.user_name, /^[0-9a-f]{64}$/, `user_name chưa hash: ${u.user_name}`);
assert.ok(!JSON.stringify(u).includes('an.nguyen'), 'email THÔ lọt lên collector');
assert.ok(!JSON.stringify(u).includes('Nguyễn'),    'tên THÔ lọt lên collector');
assert.equal(u.tier, 'vàng', 'trait không phải PII thì giữ nguyên');

// ── 3. Logout → rotate + rỗng lại ──────────────────────────────────────
UniTrack.reset();
assert.notEqual(UniTrack.currentSessionId(), sidBefore, 'logout KHÔNG xoay session_id');
assert.equal(UniTrack.sessionIndex(), idxBefore + 1, 'session_index không tăng');
assert.equal(UniTrack.previousSessionId(), sidBefore, 'previousSessionId không trỏ phiên cũ');

UniTrack.track('probe2', { screen: '/home' });
u = await userCtx();
assert.equal(u.user_id, '',   'sau logout user_id vẫn còn dữ liệu');
assert.equal(u.user_name, '', 'sau logout user_name vẫn còn dữ liệu');

console.log('PASS — user_context rỗng khi chưa login, hash khi login, session xoay khi logout');
process.exit(0);

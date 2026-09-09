// Self-check: bất biến dwell_ms = (foreground_sec + background_sec) * 1000 phải
// đúng TUYỆT ĐỐI trên mọi đường phát screen_exited, kể cả khi tab ẩn/hiện nhiều
// lần. Parity mobile c92ec6a / dc56c53 / 2a6f60a / 8fa67e9.
// Chạy: node test-dwell-invariant.mjs
import assert from 'node:assert';

let clock = 1_000_000;                       // đồng hồ ảo, ms
const advance = (ms) => { clock += ms; };

const listeners = {};
const docListeners = {};
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
  addEventListener(k, f) { (docListeners[k] ||= []).push(f); },
  removeEventListener() {},
  documentElement: { scrollHeight: 800 }, body: {}, cookie: '',
};
Object.defineProperty(globalThis, 'navigator', {
  value: { userAgent: 'ua', language: 'vi', onLine: true, sendBeacon: () => true },
  configurable: true,
});
globalThis.screen = { width: 1280, height: 800 };
globalThis.performance = { now: () => clock, getEntriesByType: () => [] };
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

/** Giả lập tab ẩn / hiện lại. */
function setVisibility(state) {
  globalThis.document.visibilityState = state;
  for (const f of docListeners.visibilitychange || []) f();
}

function exits() { return seen.filter((e) => e.n === 'screen_exited'); }

function checkInvariant(ev, label) {
  const fg = Number(ev.p.foreground_sec);
  const bg = Number(ev.p.background_sec);
  const expect = Math.round((fg + bg) * 1000);
  assert.strictEqual(Number(ev.p.dwell_ms), expect,
    `${label}: dwell_ms=${ev.p.dwell_ms} nhưng (fg=${fg} + bg=${bg})*1000=${expect}`);
  return { fg, bg };
}

// ── Case 1: sáu lần chuyển fg/bg, mỗi quãng 2,5s ────────────────────────────
// Đây là case làm lộ bug làm tròn từng window: trước khi sửa ra fg+bg=18s trong
// khi màn chỉ sống 15s.
UniTrack.setScreen('reader');
await new Promise((r) => setTimeout(r, 50));
const before = exits().length;

for (let i = 0; i < 3; i++) {
  advance(2500); setVisibility('hidden');    // đóng window fg 2,5s
  advance(2500); setVisibility('visible');   // đóng window bg 2,5s
}
UniTrack.setScreen('next');
await new Promise((r) => setTimeout(r, 50));

// Web cắt lượt xem mỗi lần ẩn tab (emitScreenEnd trên nhánh app_backgrounded),
// nên màn reader sinh nhiều screen_exited, mỗi cái chứa fg HOẶC bg. Bất biến
// phải đúng ở TỪNG event, và tổng qua tất cả lượt phải bằng thời gian màn sống.
const ev1 = exits().slice(before).filter((e) => e.p.screen === 'reader');
assert.ok(ev1.length > 0, 'không thấy screen_exited cho màn reader');
let total = 0;
for (const [i, e] of ev1.entries()) {
  const s = checkInvariant(e, `case 1 lượt ${i + 1}`);
  total += s.fg + s.bg;
}
assert.ok(Math.abs(total - 15) < 0.05,
  `case 1: màn sống 15s nhưng tổng fg+bg qua ${ev1.length} lượt = ${total}s — sai số làm tròn tích luỹ`);
assert.ok(ev1.some((e) => String(e.p.foreground_sec).includes('.')),
  'case 1: foreground_sec mất phần thập phân — bộ đếm vẫn làm tròn về giây');

// ── Case 2: bộ đếm phải reset giữa hai lượt xem ─────────────────────────────
// Parity dc56c53: không được cộng dồn sang màn kế tiếp.
const n2 = exits().length;
advance(4000);
UniTrack.setScreen('third');
await new Promise((r) => setTimeout(r, 50));
const e2 = exits().slice(n2).find((e) => e.p.screen === 'next');
assert.ok(e2, 'không thấy screen_exited cho màn next');
const s2 = checkInvariant(e2, 'case 2');
assert.ok(Math.abs(s2.fg + s2.bg - 4) < 0.05,
  `case 2: màn sống 4s nhưng fg+bg=${s2.fg + s2.bg}s — bộ đếm không reset`);

// ── Case 3: đường app_backgrounded cũng phải có dwell_ms và giữ bất biến ────
const n3 = exits().length;
advance(3000);
setVisibility('hidden');
await new Promise((r) => setTimeout(r, 50));
const e3 = exits().slice(n3).find((e) => e.p.reason === 'app_backgrounded');
assert.ok(e3, 'ẩn tab không phát screen_exited/app_backgrounded');
assert.ok(e3.p.dwell_ms !== undefined, 'nhánh app_backgrounded thiếu dwell_ms');
checkInvariant(e3, 'case 3');

// ── Case 4: số lẻ vẫn giữ nguyên phần thập phân ─────────────────────────────
setVisibility('visible');                    // case 3 để tab ở trạng thái hidden
await new Promise((r) => setTimeout(r, 50));
UniTrack.setScreen('odd');
await new Promise((r) => setTimeout(r, 50));
const n4 = exits().length;
advance(4850); setVisibility('hidden');
await new Promise((r) => setTimeout(r, 50));
const e4 = exits().slice(n4).find((e) => e.p.screen === 'odd');
assert.ok(e4, 'không thấy screen_exited cho màn odd');
assert.strictEqual(String(e4.p.foreground_sec), '4.85',
  `case 4: foreground_sec="${e4.p.foreground_sec}", mong đợi "4.85" — bộ đếm làm tròn mất mili giây`);
checkInvariant(e4, 'case 4');
setVisibility('visible');

// ── Case 5: phép làm tròn ở mức số học ──────────────────────────────────────
// Web hiện cắt lượt xem mỗi lần ẩn tab, nên trong MỘT event luôn có fg=0 hoặc
// bg=0 và tổng không bao giờ rơi vào ca float xấu. Bug trunc-vs-round bên
// Android (2a6f60a) vì thế chưa biểu hiện được qua event trên web. Vẫn chốt
// phép tính ở đây: nếu sau này web gộp fg+bg vào cùng một lượt xem (mô hình
// mobile), Math.trunc sẽ sai ngay và test này chặn trước.
assert.strictEqual(Math.round((4.85 + 3.02) * 1000), 7870,
  'phép làm tròn dwell_ms phải cho 7870');
assert.strictEqual(Math.trunc((4.85 + 3.02) * 1000), 7869,
  'giả định về lỗi float không còn đúng — xem lại cách tính dwell_ms');

// ── Case 6: quãng nền thuộc về lượt xem KẾ TIẾP, và cặp open/close phải cân ──
// Parity Android: onActivityStopped bắn screen_exited rồi
// rollScreenCountersForBackground(), nhưng backgroundedAtMs sống sót qua lần
// reset đó — quãng nền được cộng vào lượt xem sau, không phải lượt vừa đóng.
// onActivityStarted mở lại vế screen_viewed bằng reenterScreen().
setVisibility('visible');
await new Promise((r) => setTimeout(r, 50));
UniTrack.setScreen('article');
await new Promise((r) => setTimeout(r, 50));
const n6 = seen.length;

advance(10000); setVisibility('hidden');     // xem 10s rồi ẩn tab
await new Promise((r) => setTimeout(r, 50));
advance(30000); setVisibility('visible');    // để quên 30s rồi quay lại
await new Promise((r) => setTimeout(r, 50));
advance(5000);
UniTrack.setScreen('after');                 // xem thêm 5s rồi đổi màn
await new Promise((r) => setTimeout(r, 50));

const ev6 = seen.slice(n6).filter((e) => e.p.screen === 'article');
const x6 = ev6.filter((e) => e.n === 'screen_exited');
const v6 = ev6.filter((e) => e.n === 'screen_viewed');

assert.strictEqual(x6.length, 2,
  `case 6: mong đợi 2 screen_exited cho màn article, thấy ${x6.length}`);
assert.strictEqual(v6.length, 1,
  `case 6: mong đợi 1 screen_viewed mở lại khi quay lên foreground, thấy ${v6.length} — cặp open/close lệch, funnel đội Data hụt một lượt xem`);

// Lượt 1: chỉ có foreground, quãng nền chưa xảy ra.
assert.strictEqual(String(x6[0].p.foreground_sec), '10',
  `case 6 lượt 1: foreground_sec="${x6[0].p.foreground_sec}", mong đợi "10"`);
assert.strictEqual(String(x6[0].p.background_sec), '0',
  `case 6 lượt 1: background_sec="${x6[0].p.background_sec}", mong đợi "0"`);
checkInvariant(x6[0], 'case 6 lượt 1');

// Lượt 2: mang quãng nền 30s — đây là điểm đồng bộ với Android.
assert.strictEqual(String(x6[1].p.background_sec), '30',
  `case 6 lượt 2: background_sec="${x6[1].p.background_sec}", mong đợi "30" — quãng nền bị mất`);
assert.strictEqual(String(x6[1].p.foreground_sec), '5',
  `case 6 lượt 2: foreground_sec="${x6[1].p.foreground_sec}", mong đợi "5"`);
checkInvariant(x6[1], 'case 6 lượt 2');

// screen_view reenter chỉ được mang field có trong schema
// vn.fpt.ftel.snowplow/screen_view (core/src/tracker.cpp:213-225).
const allowed = new Set(['screen', 'screen_name', 'from', 'from_screen',
  'previous_screen_name', 'load_ms', 'session_id', 'session_index', 'ts',
  'event_action', 'platform']);
for (const k of Object.keys(v6[0].p)) {
  assert.ok(allowed.has(k),
    `case 6: screen_viewed reenter mang field lạ "${k}" — schema screen_view không khai, sẽ thành bad row`);
}
assert.strictEqual(v6[0].p.previous_screen_name, 'article',
  'case 6: reenter phải stamp previous = chính nó, không để provider tự suy');

console.log('PASS test-dwell-invariant.mjs — 6 case, bất biến dwell_ms=(fg+bg)*1000 giữ nguyên');

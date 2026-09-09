// Self-check: SPA tự đặt tên màn (setScreen) + hashchange KHÔNG được sinh
// event trùng. Bug thật đo trên portal session 93e91277: mỗi lần đổi route
// sinh 3 cặp view/end vì auto-capture chốt bằng full path còn app dùng '#/x'.
// Chạy: node test-spa-no-dup-screen.mjs
import assert from 'node:assert';

const listeners = {};
globalThis.window = globalThis;
Object.assign(globalThis, {
  addEventListener(k, f) { (listeners[k] ||= []).push(f); }, removeEventListener() {},
  location: { href: 'https://a.vn/demo/showcase.html#/', pathname: '/demo/showcase.html', search: '', hash: '#/' },
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
// App SPA: mỗi lần render nó tự đặt tên màn ngắn gọn.
UniTrack.setScreen('/');
await new Promise((r) => setTimeout(r, 50));
seen.length = 0;

// Điều hướng như người dùng thật: đổi hash RỒI app render + setScreen.
// Đây đúng thứ tự showcase.html làm (hashchange → render() → setScreen).
// Thứ tự đúng như showcase.html trên Chrome thật:
//   hashchange fire → onRouteChange() hạ cờ + hẹn rAF/250ms
//   → render() gọi setScreen() bật cờ lên
//   → rAF fire, thấy cờ ra sao thì quyết định ghi đè hay không.
// Bug cũ: onRouteChange hạ `screenNameManual = false`, nên tới lượt rAF cờ đã
// bị hạ rồi bật lại — nhưng giữa chừng auto-capture vẫn ghi đè bằng full path.
const go = async (hash, name) => {
  globalThis.location.hash = hash;
  globalThis.location.href = 'https://a.vn/demo/showcase.html' + hash;
  (listeners.hashchange || []).forEach((f) => f());   // hạ cờ + hẹn đo
  UniTrack.setScreen(name);                          // app đặt tên, bật cờ
  await new Promise((r) => setTimeout(r, 320));      // rAF/250ms fire ở đây
};

await go('#/products', '/products');
await go('#/cart', '/cart');

const views = seen.filter((e) => e.n === 'screen_viewed');
const ends  = seen.filter((e) => e.n === 'screen_exited');
const names = views.map((e) => e.p.screen);

// 2 lần đổi màn → đúng 2 lần vào, 2 lần ra. Không hơn.
assert.equal(views.length, 2,
  `2 lần đổi màn sinh ${views.length} screen_viewed: ${names.join(' | ')}`);
assert.equal(ends.length, 2, `sinh ${ends.length} screen_exited thay vì 2`);

// Tên màn phải là tên APP đặt, không phải full path do auto-capture chốt.
assert.deepEqual(names, ['/products', '/cart'],
  `auto-capture ghi đè tên màn của app: ${names.join(' | ')}`);
assert.ok(!names.some((n) => n.includes('showcase.html')),
  `full path lọt vào screen — auto-capture vẫn ghi đè setScreen(): ${names.join(' | ')}`);

// Luồng chuyển màn vẫn phải nối đúng.
assert.equal(views[1].p.previous_screen_name, '/products');

// Quyền đặt tên màn phải HẾT HẠN, không nhường vĩnh viễn.
//
// App gọi setScreen() một lần (mở modal, đổi tab nội bộ) rồi điều hướng URL
// thuần: auto-capture phải hoạt động trở lại. Cờ boolean chỉ hạ ở reset()
// từng làm mất TRẮNG mọi event màn hình tới lúc logout — đo được 0 event
// thay vì 4 sau 2 lần điều hướng.
seen.length = 0;
UniTrack.setScreen('/modal-noi-bo');
await new Promise((r) => setTimeout(r, 700));   // quá cửa sổ nhường quyền
seen.length = 0;

const navUrl = async (p) => {
  globalThis.location.pathname = p;
  globalThis.location.hash = '';
  globalThis.location.href = 'https://a.vn' + p;
  (listeners.popstate || []).forEach((f) => f());
  await new Promise((r) => setTimeout(r, 320));
};
await navUrl('/tin-tuc');
await navUrl('/lien-he');

const sauModal = seen.filter((e) => e.n === 'screen_viewed').map((e) => e.p.screen);
assert.deepEqual(sauModal, ['/tin-tuc', '/lien-he'],
  `setScreen() một lần rồi điều hướng URL làm auto-capture chết: ${sauModal.join(' | ') || '(RỖNG)'}`);

// Bất biến nguồn — bổ sung cho phần hành vi ở trên.
//
// Bug gốc (onRouteChange hạ quyền) chỉ lộ trên Chrome: ở đó rAF chạy SAU
// setScreen(), nên quyền bị hạ rồi bật lại và callback thấy đúng khoảnh khắc
// quyền đang thuộc URL. Trong Node, setCurrentScreen() luôn kịp set mốc trước
// khi rAF chạy nên hành vi vẫn đúng — không tái hiện được. Kiểm thẳng vào
// source để lần sửa sau không lặng lẽ đưa dòng hạ quyền trở lại.
const { readFileSync } = await import('node:fs');
const body = readFileSync(new URL('./src/auto-capture.ts', import.meta.url), 'utf8')
  .replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');   // bỏ comment
const rc = body.slice(body.indexOf('function onRouteChange'),
                      body.indexOf('function emitScreen('));
assert.ok(!/manualScreenName\s*=\s*''/.test(rc),
  'onRouteChange hạ quyền đặt tên màn → auto-capture ghi đè tên app đặt (đo trên Chrome: 4 event/lần đổi hash thay vì 2)');

console.log('PASS — SPA setScreen + hashchange sinh đúng 1 cặp/màn, giữ tên app đặt');
process.exit(0);

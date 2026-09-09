// Self-check: đứng yên trên web KHÔNG được sinh event.
// Bắt đúng bug thật: flush → fetch tới collector → network-interceptor bắt
// → emit network_request → vào buffer → flush tiếp → vòng lặp vô hạn.
// Chạy: node test-no-feedback-loop.mjs
import assert from 'node:assert';

// window PHẢI là chính globalThis, y như browser thật: interceptor patch
// `window.fetch` còn provider gọi `fetch()` trần (→ globalThis.fetch). Tách
// đôi hai thứ này thì interceptor nằm ngoài đường đi và test mất hết ý nghĩa.
const listeners = {};
globalThis.window = globalThis;
Object.assign(globalThis, {
  addEventListener(k, f) { (listeners[k] ||= []).push(f); },
  removeEventListener() {},
  location: { href: 'https://app.vn/home', pathname: '/home', search: '', hash: '' },
  innerWidth: 1280, innerHeight: 800,
  history: { pushState() {}, replaceState() {} },
  requestAnimationFrame: (f) => setTimeout(f, 0),
});
globalThis.XMLHttpRequest = class { open() {} send() {} setRequestHeader() {}
  addEventListener() {} };
globalThis.document = {
  title: 'Home', referrer: '', visibilityState: 'visible',
  addEventListener() {}, removeEventListener() {},
  documentElement: { scrollHeight: 800 }, body: {}, cookie: '',
};
Object.defineProperty(globalThis, 'navigator', {
  value: { userAgent: 'ua', language: 'vi', onLine: true, sendBeacon: () => true },
  configurable: true,
});
globalThis.screen = { width: 1280, height: 800 };
globalThis.performance = { now: () => Date.now(), getEntriesByType: () => [] };
globalThis.localStorage = {
  _d: {}, getItem(k) { return this._d[k] ?? null; },
  setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; },
};
globalThis.sessionStorage = globalThis.localStorage;

const COLLECTOR = 'https://collector.fpt.vn';
let hits = 0;
globalThis.fetch = async (u) => {
  const url = String(u);
  if (url.includes('unitrack.config.json')) {
    return { ok: true, json: async () => ({
      apiKey: 'k', endpoint: '',            // FPT Life: core ingest RỖNG
      sdk_config: { trackNetwork: true, verboseLogging: false, flushIntervalMs: 20 },
      snowplow: {
        enabled: true, endpoint: COLLECTOR + '/sp/key', appId: '567',
        iglu_vendor: 'vn.fpt.ftel.snowplow',
        entities: { user_context: 'user_context', core_action: 'core_action' },
      },
    }) };
  }
  if (url.startsWith(COLLECTOR)) hits++;     // request thật lên collector
  return { ok: true, status: 200 };
};


const { UniTrack } = await import('./dist/unitrack.esm.js');
await UniTrack.initializeFromConfig('/unitrack.config.json');

// Đứng yên: không click, không điều hướng. Chỉ để timer chạy.
await new Promise((r) => setTimeout(r, 300));   // ~15 chu kỳ flush 20ms
const afterIdle = hits;

// Một request tới collector do event khởi động (app_start/screen_viewed) là
// hợp lệ. Cái KHÔNG hợp lệ là số request tăng đều theo mỗi nhịp flush.
await new Promise((r) => setTimeout(r, 300));
const growth = hits - afterIdle;

assert.equal(growth, 0,
  `đứng yên vẫn sinh ${growth} request trong 15 nhịp flush — vòng lặp chưa đứt`);

console.log(`PASS — đứng yên không sinh event (tổng ${hits} request lúc khởi động, 0 tăng thêm)`);
process.exit(0);   // SDK để lại flush timer chạy nền

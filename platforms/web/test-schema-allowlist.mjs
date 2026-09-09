// Self-check: SDK không bao giờ được tự chế schema iglu từ tên event.
// Bug thật: event nghiệp vụ (add_to_cart, purchase…) rơi vào nhánh
// `default: return raw` nên sinh iglu:<vendor>/add_to_cart/... — schema đó
// KHÔNG có trên Iglu registry → enricher ResolutionError → bad row.
// Mobile chỉ dùng đúng 6 schema (đo portal project 8: mọi camera_* đều đi
// qua ev_click/ev_result/ev_api, tên nghiệp vụ nằm ở event_action).
// Chạy: node test-schema-allowlist.mjs
import assert from 'node:assert';

const sent = [];
globalThis.window = { addEventListener() {}, location: { href: 'https://a.vn/x' }, innerWidth: 1, innerHeight: 1 };
globalThis.document = { title: 'T', referrer: '' };
Object.defineProperty(globalThis, 'navigator', {
  value: { userAgent: 'ua', language: 'vi', onLine: true }, configurable: true });
globalThis.screen = { width: 1, height: 1 };
globalThis.fetch = async (_u, o) => { sent.push(JSON.parse(o.body)); return { ok: true }; };

const { SnowplowProvider } = await import('./dist/unitrack.esm.js');

// Đúng bộ event_names portal đang khai — 6 loại, không hơn.
const EVENT_NAMES = {
  click: 'ev_click', result: 'ev_result', screen_view: 'screen_view',
  screen_end: 'screen_end', crash: 'ev_crash', api: 'ev_api', session: 'ev_session',
};
const p = new SnowplowProvider({
  endpoint: 'https://c', appId: 'web', igluVendor: 'vn.fpt.ftel.snowplow',
  defaultVersion: '1-0-0', eventNames: EVENT_NAMES,
  entities: { core_action: 'core_action' },
  ownSchemaEvents: ['app_background', 'app_foreground'],
  dropEvents: ['app_start'],
  // KHÔNG khai businessEventKinds — app dùng helper trackResult()/trackClick()
  // thì kind đi kèm ngay lời gọi, y như mobile gọi trackingResultEvent().
  businessKind: 'click',
});

// Trộn event auto-capture, nghiệp vụ, lifecycle và vài tên bịa.
for (const n of ['click', 'screen_viewed', 'screen_exited', 'network_request', 'crash',
                 'session_ended', 'product_viewed',
                 'login', 'logout', 'hero_cta', 'bat_ky_ten_gi',
                 'app_background', 'app_foreground', 'app_start']) {
  p.track(n, { session_id: 's1', screen: '/x' });
}
// Event nghiệp vụ đi qua helper: `_kind` do CALLER truyền, không có dòng nào
// trong config nhắc tới add_to_cart/purchase/product_share.
for (const n of ['add_to_cart', 'purchase', 'product_share']) {
  p.track(n, { session_id: 's1', screen: '/x', _kind: 'result', action: n, status: 'success' });
}
await p.flush();

const rows = sent.flatMap((b) => b.data).map((e) => {
  const ue = JSON.parse(e.ue_pr).data;
  return { schema: ue.schema, action: ue.data.event_action, data: ue.data };
});

// Mọi schema phải nằm trong tập cho phép: 7 kind + 2 event có schema riêng.
const CHO_PHEP = new Set([
  ...Object.values(EVENT_NAMES), 'app_background', 'app_foreground',
]);
const la = rows
  .map((r) => r.schema.split('/')[1])
  .filter((n) => !CHO_PHEP.has(n));
assert.deepEqual([...new Set(la)], [],
  `SDK tự chế schema không có trên Iglu → bad row: ${[...new Set(la)].join(', ')}`);

// app_start bị chặn hẳn (mobile không gửi lên Snowplow, Iglu không có schema).
assert.ok(!rows.some((r) => r.action === 'app_start'), 'app_start không được gửi');

// Event nghiệp vụ vẫn phải phân biệt được qua event_action — đó là cách đội
// Data pivot với mobile.
// businessEventKinds định tuyến per-event: giỏ hàng/thanh toán là KẾT QUẢ,
// không phải cú bấm — đội Data đo tỉ lệ thành công trên ev_result.
const cart = rows.find((r) => r.action === 'add_to_cart');
assert.ok(cart, 'mất event add_to_cart');
assert.equal(cart.schema, 'iglu:vn.fpt.ftel.snowplow/ev_result/jsonschema/1-0-0',
  'trackResult() không định tuyến được về ev_result — kind phải theo lời gọi, không cần config');
for (const a of ['purchase', 'product_share']) {
  assert.equal(rows.find((r) => r.action === a).schema,
    'iglu:vn.fpt.ftel.snowplow/ev_result/jsonschema/1-0-0', `${a} sai schema`);
}
// `_kind` là chỉ dẫn định tuyến — không được lọt lên collector.
assert.ok(!rows.some((r) => '_kind' in r.data), '_kind lọt vào payload gửi đi');
// Event không khai trong map vẫn rơi về businessKind mặc định.
assert.equal(rows.find((r) => r.action === 'hero_cta').schema,
  'iglu:vn.fpt.ftel.snowplow/ev_click/jsonschema/1-0-0');

// Event có schema riêng giữ nguyên tên.
const bg = rows.find((r) => r.action === 'app_background');
assert.equal(bg.schema, 'iglu:vn.fpt.ftel.snowplow/app_background/jsonschema/1-0-0');

// ev_result bên mobile luôn mang `action` + `status` (88/88 trên project 8) —
// event nghiệp vụ web định tuyến vào đây cũng phải có, nếu không query mobile
// áp lên web trả rỗng.
for (const r of rows.filter((x) => x.schema.includes('/ev_result/'))) {
  assert.ok(r.data.action, `ev_result "${r.action}" thiếu field action`);
  assert.ok(r.data.status, `ev_result "${r.action}" thiếu field status`);
}

// `_kind` không được lọt lên collector dù đi đường nào. Ở đây kiểm payload
// Snowplow; đường portal do track() lọc (chỉ SnowplowProvider nhận `_kind`).
assert.ok(!rows.some((r) => '_kind' in r.data),
  '_kind lọt vào payload gửi lên collector');

console.log(`PASS — ${rows.length} event chỉ dùng ${new Set(rows.map(r => r.schema)).size} schema hợp lệ, không tự chế`);
process.exit(0);

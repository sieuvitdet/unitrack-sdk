// Self-check: payload Snowplow của web phải khớp convention mobile.
// Chạy: node test-snowplow-parity.mjs
import assert from 'node:assert';
import { SnowplowProvider } from './dist/unitrack.esm.js';

// Stub môi trường browser tối thiểu.
const sent = [];
globalThis.window = { addEventListener() {}, location: { href: 'https://a.vn/x' }, innerWidth: 1, innerHeight: 2 };
globalThis.document = { title: 'T', referrer: '' };
Object.defineProperty(globalThis, 'navigator', { value: { userAgent: 'ua', language: 'vi', onLine: true }, configurable: true });
globalThis.screen = { width: 1, height: 2 };
globalThis.fetch = async (_u, o) => { sent.push(JSON.parse(o.body)); return { ok: true }; };


const cfg = {
  endpoint: 'https://c', appId: '567', igluVendor: 'vn.fpt.ftel.snowplow',
  defaultVersion: '1-0-0',
  eventNames: { click: 'ev_click', screen_view: 'screen_view', screen_end: 'screen_end', session: 'ev_session' },
  entities: { user_context: 'user_context', core_action: 'core_action' },
  dropEvents: ['app_foreground'],
};
const p = new SnowplowProvider(cfg);
p.setUser('u1', { tier: 'gold' });

const parse = (i) => {
  const ev = sent[0].data[i];
  return { ue: JSON.parse(ev.ue_pr), co: ev.co ? JSON.parse(ev.co) : null };
};

p.track('click', { session_id: 's1', screen: 'home', element_key: 'btn' });
p.track('screen_exited', { session_id: 's1', screen: 'home', screen_name: 'home',
  dwell_ms: 900, foreground_sec: '1', background_sec: '0',
  is_exit_screen: 'false', reason: 'screen_change' });
p.track('screen_viewed', { session_id: 's1', screen: 'home', load_ms: 120 });
p.track('app_foreground', { session_id: 's1' });   // phải bị drop
await p.flush();

assert.equal(sent.length, 1);
assert.equal(sent[0].data.length, 3, 'drop_events không hoạt động');

const a = parse(0);
assert.equal(a.ue.data.schema, 'iglu:vn.fpt.ftel.snowplow/ev_click/jsonschema/1-0-0');
// screen_exited phải đi schema RIÊNG, không gộp vào screen_view.
const b = parse(1);
assert.equal(b.ue.data.schema, 'iglu:vn.fpt.ftel.snowplow/screen_end/jsonschema/1-0-0');

// screen_end mang đủ field theo contract mobile (core C++ tracker.cpp:213-217
// + AppLifecycleObserver): screen_name, is_exit_screen, reason, fg/bg sec.
for (const f of ['screen_name', 'is_exit_screen', 'reason', 'foreground_sec', 'background_sec']) {
  assert.ok(b.ue.data.data[f] !== undefined, `screen_end thiếu ${f}`);
}

// screen_viewed → screen_view, và load_ms đi KÈM chứ không thành event riêng.
const c = parse(2);
assert.equal(c.ue.data.schema, 'iglu:vn.fpt.ftel.snowplow/screen_view/jsonschema/1-0-0');
assert.equal(c.ue.data.data.load_ms, 120);
// Không còn schema screen_load_completed nào được bắn.
assert.ok(!sent[0].data.some((e) => JSON.parse(e.ue_pr).data.schema.includes('load')),
  'vẫn còn event screen_load_completed');

// Entity: đúng 2 cái đã đăng ký, application_context KHÔNG đăng ký nên vắng.
const names = a.co.data.map((c) => c.schema);
assert.deepEqual(names, [
  'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
  'iglu:vn.fpt.ftel.snowplow/core_action/jsonschema/1-0-0',
]);

// core_action mang raw action_name (không phải kind) + session_id.
const core = a.co.data[1].data;
assert.equal(core.action_name, 'click');
assert.equal(core.session_id, 's1');
assert.equal(core.screen, 'home');
assert.equal(core.element_key, 'btn');
assert.equal(core.is_headless, 'false');
// Mọi field entity là string — schema Iglu FPT khai string.
for (const c of a.co.data) for (const v of Object.values(c.data)) assert.equal(typeof v, 'string');

// Field theo kind — parity iOS trackingSession/trackingAPI.
sent.length = 0;
p.track('session_ended', { session_id: 's1' });
p.track('network_request', { session_id: 's1', url: 'https://a/b', method: 'GET', status_code: 200 });
await p.flush();
const sess = JSON.parse(sent[0].data[0].ue_pr).data.data;
assert.equal(sess.action, 'session_ended', 'ev_session thiếu field `action` (mobile có)');
const api = JSON.parse(sent[0].data[1].ue_pr).data.data;
assert.equal(api.status, 200, 'ev_api thiếu field `status` (mobile dùng tên này, không phải status_code)');
assert.equal(api.status_code, 200, 'status_code phải giữ lại cho consumer web cũ');

console.log('PASS — web Snowplow payload khớp convention mobile');

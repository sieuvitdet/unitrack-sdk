// Self-check: MỌI provider phải nhận được event_action, không riêng Snowplow.
// Bug thật: gắn trong SnowplowProvider nên đường portal-ingest để trống —
// đo trên portal 109/112 hàng provider=unitrack có event_action NULL, trong
// khi bản mirror Snowplow của cùng event lại đủ.
import assert from 'node:assert';
const listeners = {}; globalThis.window = globalThis;
Object.assign(globalThis, { addEventListener(k,f){(listeners[k]||=[]).push(f);}, removeEventListener(){},
  location:{href:'https://a.vn/x',pathname:'/x',search:'',hash:''}, innerWidth:1, innerHeight:1,
  history:{pushState(){},replaceState(){}}, requestAnimationFrame:(f)=>setTimeout(f,0) });
globalThis.document = { title:'T', referrer:'', visibilityState:'visible', readyState:'complete',
  addEventListener(){}, removeEventListener(){}, documentElement:{scrollHeight:1}, body:{}, cookie:'' };
Object.defineProperty(globalThis,'navigator',{value:{userAgent:'ua',language:'vi',onLine:true,sendBeacon:()=>true},configurable:true});
globalThis.screen = { width:1, height:1 };
globalThis.performance = { now:()=>Date.now(), getEntriesByType:()=>[], markResourceTiming(){} };
globalThis.localStorage = { _d:{}, getItem(k){return this._d[k]??null;}, setItem(k,v){this._d[k]=String(v);}, removeItem(k){delete this._d[k];} };
globalThis.sessionStorage = globalThis.localStorage;
globalThis.XMLHttpRequest = class { open(){} send(){} setRequestHeader(){} addEventListener(){} };
globalThis.fetch = async () => ({ ok:true, status:200, json: async()=>({}) });

const { UniTrack } = await import(new URL('./dist/unitrack.esm.js', import.meta.url).href);
const http = [], snow = [];
UniTrack.addProvider({ name:'HttpProvider', init(){}, track(n,p){ http.push({n,p}); } });
UniTrack.addProvider({ name:'SnowplowProvider', init(){}, track(n,p){ snow.push({n,p}); } });
UniTrack.initialize('k', { endpoint:'', verboseLogging:false, trackNetwork:false });
await new Promise(r => setTimeout(r, 300));

UniTrack.track('click', { element_key: 'btn' });
UniTrack.trackResult('add_to_cart', 'success', { product_id: 'p1' });
UniTrack.trackClick('product_viewed', { product_id: 'p1' });
UniTrack.customTrack('purchase', { action: 'order_placed', data: { total: 100 } });

const thieu = http.filter((e) => e.p.event_action == null).map((e) => e.n);
assert.deepEqual(thieu, [],
  `event_action NULL trên đường portal: ${thieu.join(', ')}`);

// Mặc định = tên event; caller truyền action riêng thì giữ nguyên.
assert.equal(http.find((e) => e.n === 'click').p.event_action, 'click');
assert.equal(http.find((e) => e.n === 'purchase').p.event_action, 'order_placed',
  'customTrack(action:) phải thắng giá trị mặc định');

// Hai đường phải khớp nhau cho cùng một lần track().
for (const h of http) {
  const s = snow.find((x) => x.n === h.n);
  if (s) assert.equal(s.p.event_action, h.p.event_action,
    `hai đường lệch event_action cho "${h.n}"`);
}

console.log(`PASS — ${http.length} event, mọi provider đều có event_action và khớp nhau`);
process.exit(0);

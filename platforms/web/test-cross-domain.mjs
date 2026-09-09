// Kiểm chứng cross-domain: trang đích nối đúng session từ tham số _sp.
import assert from 'node:assert';
const SID='11111111-2222-3333-4444-555555555555';
const listeners={}; globalThis.window=globalThis;
Object.assign(globalThis,{addEventListener(k,f){(listeners[k]||=[]).push(f);},removeEventListener(){},
 location:{href:`https://checkout.vn/?_sp=${SID}.${Date.now()}.${SID}..shop.vn.web`,
   pathname:'/',search:`?_sp=${SID}.${Date.now()}.${SID}..shop.vn.web`,hash:''},
 innerWidth:1,innerHeight:1,history:{pushState(){},replaceState(){}},requestAnimationFrame:(f)=>setTimeout(f,0)});
const docL={};
globalThis.document={title:'T',referrer:'',visibilityState:'visible',readyState:'complete',
 addEventListener(k,f){(docL[k]||=[]).push(f);},removeEventListener(){},
 documentElement:{scrollHeight:1},body:{},cookie:''};
Object.defineProperty(globalThis,'navigator',{value:{userAgent:'ua',language:'vi',onLine:true,sendBeacon:()=>true},configurable:true});
globalThis.screen={width:1,height:1};
globalThis.performance={now:()=>Date.now(),getEntriesByType:()=>[],markResourceTiming(){}};
globalThis.localStorage={_d:{},getItem(k){return this._d[k]??null;},setItem(k,v){this._d[k]=String(v);},removeItem(k){delete this._d[k];}};
globalThis.sessionStorage=globalThis.localStorage;
globalThis.XMLHttpRequest=class{open(){}send(){}setRequestHeader(){}addEventListener(){}};
globalThis.fetch=async()=>({ok:true,status:200,json:async()=>({})});


const {UniTrack,readCrossDomainSession}=await import(new URL('./dist/unitrack.esm.js', import.meta.url).href);
const doc=readCrossDomainSession();
assert.equal(doc.sessionId,SID,'readCrossDomainSession không đọc đúng');
assert.equal(doc.sourceId,'shop.vn','link cũ dạng hostname phải parse được');
UniTrack.initialize('k',{endpoint:'',verboseLogging:false,trackNetwork:false});
assert.equal(UniTrack.currentSessionId(),SID,'SDK không nối session từ _sp');
assert.equal(UniTrack.sessionIndex(),1,'adopt không được tăng session_index');
// Phía GHI: gọi PLUGIN THẬT trang trí một thẻ <a>, rồi đọc lại chuỗi _sp nó
// sinh ra. Tự dựng chuỗi bằng tay thì test chỉ kiểm chính nó, không kiểm code.
const { crossDomainPlugin } = await import(new URL('./dist/unitrack.esm.js', import.meta.url).href);
class FakeAnchor { constructor(h){ this.href=h; } getAttribute(){ return null; } closest(){ return this; } }
globalThis.HTMLAnchorElement = FakeAnchor;
globalThis.location.hostname = 'checkout.vn';
globalThis.location.href = 'https://checkout.vn/';
globalThis.location.origin = 'https://checkout.vn';

const a = new FakeAnchor('https://doitac.vn/uu-dai');
// Chụp riêng listener của plugin: auto-capture cũng gắn click và nó cần
// HTMLElement thật, gọi nhầm sẽ ném lỗi không liên quan.
const truoc = (docL.click || []).length;
const off = crossDomainPlugin({
  shouldDecorate: () => true,
  getSessionId: () => SID,
  // KHÔNG truyền sourceId → plugin rơi về location.hostname
}).install(() => {});
(docL.click || []).slice(truoc).forEach((f) => f({ target: a }));
off?.();

assert.ok(a.href.includes('_sp='), 'plugin không trang trí link');
const raw = new URL(a.href).searchParams.get('_sp');
globalThis.location.search = '?_sp=' + raw;
const round = readCrossDomainSession();
assert.equal(round.sessionId, SID, 'chuỗi _sp plugin sinh ra phải đọc lại đúng session');
assert.equal(round.sourceId, 'checkout-vn',
  `sourceId sai: "${round.sourceId}" — dấu chấm trong hostname làm trang đích split nhầm`);

console.log('PASS — trang đích nối đúng session', SID.slice(0,8), 'từ', doc.sourceId);
process.exit(0);

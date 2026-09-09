// `_kind` chỉ SnowplowProvider được nhận. Provider khác (HttpProvider → portal)
// không hiểu field này và từng đẩy nguyên nó lên portal.
import assert from 'node:assert';
const listeners={}; globalThis.window=globalThis;
Object.assign(globalThis,{addEventListener(k,f){(listeners[k]||=[]).push(f);},removeEventListener(){},
 location:{href:'https://a.vn/x',pathname:'/x',search:'',hash:''},innerWidth:1,innerHeight:1,
 history:{pushState(){},replaceState(){}},requestAnimationFrame:(f)=>setTimeout(f,0)});
globalThis.document={title:'T',referrer:'',visibilityState:'visible',readyState:'complete',
 addEventListener(){},removeEventListener(){},documentElement:{scrollHeight:1},body:{},cookie:''};
Object.defineProperty(globalThis,'navigator',{value:{userAgent:'ua',language:'vi',onLine:true,sendBeacon:()=>true},configurable:true});
globalThis.screen={width:1,height:1};
globalThis.performance={now:()=>Date.now(),getEntriesByType:()=>[],markResourceTiming(){}};
globalThis.localStorage={_d:{},getItem(k){return this._d[k]??null;},setItem(k,v){this._d[k]=String(v);},removeItem(k){delete this._d[k];}};
globalThis.sessionStorage=globalThis.localStorage;
globalThis.XMLHttpRequest=class{open(){}send(){}setRequestHeader(){}addEventListener(){}};
globalThis.fetch=async()=>({ok:true,status:200,json:async()=>({})});

const {UniTrack}=await import(new URL('./dist/unitrack.esm.js', import.meta.url).href);
const http=[], snow=[];
UniTrack.addProvider({name:'HttpProvider',init(){},track(_n,p){http.push(p);}});
UniTrack.addProvider({name:'SnowplowProvider',init(){},track(_n,p){snow.push(p);}});
UniTrack.initialize('k',{endpoint:'',verboseLogging:false,trackNetwork:false});
UniTrack.trackResult('add_to_cart','success',{product_id:'p1'});

const leak=http.find(x=>'_kind' in x);
assert.ok(!leak, '_kind lọt sang HttpProvider → nằm trong properties trên portal');
assert.ok(snow.some(x=>x._kind==='result'), 'SnowplowProvider phải nhận được _kind để định tuyến');
assert.ok(http.some(x=>x.action==='add_to_cart'&&x.status==='success'), 'mất action/status');
console.log('PASS — _kind chỉ tới SnowplowProvider, không lọt lên portal');
process.exit(0);

// End-to-end test for the ingest server. Spawns server, POSTs a batch,
// verifies storage. Run after `npm install`.

const { spawn } = require('child_process');
const http      = require('http');
const fs        = require('fs');

const DB    = '/tmp/ut_ingest_test.db';
const PORT  = 18787;

if (fs.existsSync(DB)) fs.unlinkSync(DB);

const srv = spawn('node', ['server.js'], {
  env: { ...process.env, PORT, DB_PATH: DB, API_KEY: 'test-key' },
  stdio: ['ignore', 'pipe', 'inherit'],
});

function postBatch(events) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(events);
    const req = http.request({
      hostname: '127.0.0.1', port: PORT,
      path: '/v1/events', method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer test-key',
        'Content-Length': Buffer.byteLength(body),
      }
    }, res => {
      let s = '';
      res.on('data', d => s += d);
      res.on('end', () => resolve({ status: res.statusCode, body: s }));
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

function get(path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1', port: PORT, path, method: 'GET',
      headers: { 'Authorization': 'Bearer test-key' }
    }, res => {
      let s = '';
      res.on('data', d => s += d);
      res.on('end', () => resolve({ status: res.statusCode, body: s }));
    });
    req.on('error', reject);
    req.end();
  });
}

(async () => {
  // Wait for server up.
  for (let i = 0; i < 30; i++) {
    try {
      const r = await get('/healthz');
      if (r.status === 200) break;
    } catch {}
    await new Promise(r => setTimeout(r, 100));
  }

  let pass = 0, fail = 0;
  const check = (cond, msg) => {
    if (cond) { console.log(`  PASS: ${msg}`); pass++; }
    else      { console.log(`  FAIL: ${msg}`); fail++; }
  };

  // ─── insert 3 events ──────────────────────────────────────────────────
  const r1 = await postBatch([
    { event_id: 'a1', event_name: 'tap',         timestamp: 1, session_id: 's', screen: 'Home',  properties: { x: 1 }},
    { event_id: 'a2', event_name: 'screen_view', timestamp: 2, session_id: 's', screen: 'Profile' },
    { event_id: 'a3', event_name: 'tap',         timestamp: 3, session_id: 's', screen: 'Home' },
  ]);
  const j1 = JSON.parse(r1.body);
  check(r1.status === 200,             '200 on POST');
  check(j1.received === 3,             'received == 3');
  check(j1.inserted === 3,             'inserted == 3');

  // ─── duplicates ignored ───────────────────────────────────────────────
  const r2 = await postBatch([
    { event_id: 'a1', event_name: 'tap', timestamp: 999 },  // dup
    { event_id: 'a4', event_name: 'tap', timestamp: 4 },
  ]);
  const j2 = JSON.parse(r2.body);
  check(j2.inserted === 1,             'dup ignored, inserted == 1');

  // ─── invalid events rejected ──────────────────────────────────────────
  const r3 = await postBatch([{ event_name: 'no_id' }]);
  const j3 = JSON.parse(r3.body);
  check(j3.rejected === 1,             'invalid event rejected');

  // ─── auth ─────────────────────────────────────────────────────────────
  const noauth = await new Promise(r => {
    const req = http.request({
      hostname: '127.0.0.1', port: PORT, path: '/v1/events', method: 'POST',
      headers: { 'Content-Type': 'application/json' }
    }, res => { res.on('data', () => {}); res.on('end', () => r(res.statusCode)); });
    req.end('[]');
  });
  check(noauth === 401,                '401 without auth');

  // ─── stats ────────────────────────────────────────────────────────────
  const r4 = await get('/v1/stats');
  const j4 = JSON.parse(r4.body);
  check(j4.total === 4,                'stats total = 4');
  check(j4.by_event.find(e => e.event_name === 'tap')?.count === 3, 'tap count = 3');

  console.log(`\nResult: ${pass} passed, ${fail} failed`);
  srv.kill('SIGTERM');
  try { fs.unlinkSync(DB); fs.unlinkSync(DB + '-shm'); fs.unlinkSync(DB + '-wal'); } catch {}
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => {
  console.error(e);
  srv.kill('SIGTERM');
  process.exit(2);
});

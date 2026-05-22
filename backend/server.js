// UniTrack reference ingest server.
//
// A minimal HTTPS POST endpoint that receives event batches from the SDK,
// validates the schema, and persists to a local SQLite database. This is
// a reference implementation — production deployments would push to
// Kafka / ClickHouse / Druid instead.
//
// Endpoints:
//   POST /v1/events       — body: JSON array of events
//   GET  /v1/events       — list recently ingested events (debug)
//   GET  /v1/stats        — counts by event_name
//   GET  /healthz         — liveness probe

const express = require('express');
const { DatabaseSync } = require('node:sqlite');
const path     = require('path');

const PORT    = process.env.PORT    || 8787;
const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'ingest.db');
const API_KEY = process.env.API_KEY || '';   // empty = no auth (dev only)

const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode = WAL;');
db.exec(`
  CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id    TEXT UNIQUE NOT NULL,
    event_name  TEXT NOT NULL,
    timestamp   INTEGER NOT NULL,
    session_id  TEXT,
    user_id     TEXT,
    screen      TEXT,
    properties  TEXT,
    received_at INTEGER NOT NULL,
    source_ip   TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_events_event_name ON events(event_name);
  CREATE INDEX IF NOT EXISTS idx_events_timestamp  ON events(timestamp);
`);

const insertStmt = db.prepare(`
  INSERT OR IGNORE INTO events
    (event_id, event_name, timestamp, session_id, user_id, screen,
     properties, received_at, source_ip)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);
function insertMany(events, ip) {
  db.exec('BEGIN');
  let n = 0;
  try {
    for (const e of events) {
      const r = insertStmt.run(
        e.event_id, e.event_name, e.timestamp,
        e.session_id ?? null, e.user_id ?? null, e.screen ?? null,
        JSON.stringify(e.properties ?? {}),
        Date.now(),
        ip
      );
      if (r.changes > 0) n++;
    }
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
  return n;
}

const app = express();
app.use(express.json({ limit: '5mb' }));

function authMiddleware(req, res, next) {
  if (!API_KEY) return next();
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/);
  if (!m || m[1] !== API_KEY) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  next();
}

// Validate event structure: event_id, event_name, timestamp required.
function isValid(e) {
  return e
    && typeof e.event_id   === 'string'
    && typeof e.event_name === 'string'
    && typeof e.timestamp  === 'number';
}

app.post('/v1/events', authMiddleware, (req, res) => {
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress || '';
  let batch = req.body;
  if (!Array.isArray(batch)) batch = [batch];

  const valid = batch.filter(isValid);
  const rejected = batch.length - valid.length;
  let inserted = 0;
  try {
    inserted = insertMany(valid, ip);
  } catch (err) {
    console.error('insert error', err);
    return res.status(500).json({ error: 'persist_failed' });
  }
  res.json({ received: batch.length, inserted, rejected });
});

app.get('/v1/events', authMiddleware, (req, res) => {
  const limit = Math.min(parseInt(req.query.limit, 10) || 50, 500);
  const rows  = db.prepare(
    'SELECT id, event_id, event_name, timestamp, session_id, user_id, ' +
    'screen, properties, received_at FROM events ' +
    'ORDER BY id DESC LIMIT ?'
  ).all(limit);
  res.json(rows.map(r => ({ ...r, properties: JSON.parse(r.properties || '{}') })));
});

app.get('/v1/stats', authMiddleware, (req, res) => {
  const rows = db.prepare(
    'SELECT event_name, COUNT(*) AS count FROM events ' +
    'GROUP BY event_name ORDER BY count DESC'
  ).all();
  const total = db.prepare('SELECT COUNT(*) AS n FROM events').get();
  res.json({ total: total.n, by_event: rows });
});

app.get('/healthz', (req, res) => {
  res.type('text').send('ok');
});

app.listen(PORT, () => {
  console.log(`[UniTrack ingest] listening on :${PORT}`);
  console.log(`[UniTrack ingest] DB ${DB_PATH}`);
  if (!API_KEY) console.log('[UniTrack ingest] WARNING: no API_KEY set, auth disabled');
});

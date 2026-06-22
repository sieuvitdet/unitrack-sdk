// Portal database — schema, migrations, and the shared connection.
//
// Multi-project model:
//   projects ──1:N── events
//   projects ──1:N── event_defs        (declared event-name conventions)
//   projects ──1:N── event_mappings    (element_key → event_def, drag-and-drop)
//
// A project owns an api_key; the SDK sends that key, and ingest attributes
// every event to the matching project.

const { DatabaseSync } = require('node:sqlite');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'events.db');
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode = WAL;');
db.exec('PRAGMA foreign_keys = ON;');

// 1) Create tables. (No indexes on new columns yet — a pre-existing `events`
//    table may not have those columns until the migration step below runs.)
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,            -- scrypt: salt:hash (hex)
    role          TEXT NOT NULL DEFAULT 'user',  -- user | admin
    created_at    INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS sessions (
    token       TEXT PRIMARY KEY,
    user_id     INTEGER NOT NULL,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS projects (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id    INTEGER,                    -- the user who owns this project
    name        TEXT NOT NULL,
    app_bundle  TEXT,                       -- iOS bundle id / Android package
    source_type TEXT,                       -- native_ios | native_android | flutter | react_native
    api_key     TEXT UNIQUE NOT NULL,
    created_at  INTEGER NOT NULL,
    -- Multi-provider: when the project forwards to Snowplow, the portal acts as
    -- a collector proxy. If sp_forward_url is set, received Snowplow events are
    -- relayed to the real collector; blank = collect-only (portal is the sink).
    sp_forward_url TEXT,
    providers      TEXT                      -- JSON array e.g. ["snowplow","firebase"]
  );

  CREATE TABLE IF NOT EXISTS events (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id    INTEGER,
    event_id      TEXT UNIQUE NOT NULL,
    event_name    TEXT NOT NULL,
    timestamp     INTEGER NOT NULL,
    session_id    TEXT,
    user_id       TEXT,
    screen        TEXT,                      -- current screen at event time
    screen_name   TEXT,                      -- resolved class/route name
    class_name    TEXT,                      -- originating class/widget/component
    element_key   TEXT,                      -- tapped element identifier
    platform      TEXT,
    app_version   TEXT,
    properties    TEXT,
    device        TEXT,
    received_at   INTEGER NOT NULL,
    source_ip     TEXT,
    provider      TEXT NOT NULL DEFAULT 'unitrack'  -- unitrack | snowplow | firebase
  );

  CREATE TABLE IF NOT EXISTS event_defs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  INTEGER NOT NULL,
    UNIQUE(project_id, name)
  );

  CREATE TABLE IF NOT EXISTS event_mappings (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id    INTEGER NOT NULL,
    element_key   TEXT NOT NULL,
    event_def_id  INTEGER NOT NULL,
    created_at    INTEGER NOT NULL,
    UNIQUE(project_id, element_key)
  );

  -- Snowplow event mapping: turns a raw UniTrack event name into a Snowplow
  -- event when forwarding, WITHOUT changing the app. When the Snowplow team
  -- adds a new event type, you add a row here instead of rebuilding the app.
  --   mode self_describing : self-describing event using the schema column
  --   mode structured      : Snowplow Structured event (category unitrack)
  --   forward 1/0          : relay to the project Snowplow collector or not
  CREATE TABLE IF NOT EXISTS sp_event_maps (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL,
    event_name  TEXT NOT NULL,           -- raw UniTrack event name (e.g. "check")
    mode        TEXT NOT NULL DEFAULT 'self_describing',
    schema      TEXT,                     -- iglu schema URI (self_describing only)
    forward     INTEGER NOT NULL DEFAULT 1,
    created_at  INTEGER NOT NULL,
    UNIQUE(project_id, event_name)
  );

  -- App sessions: a materialized view of each tracking session, reconstructed
  -- from the raw events stream (grouped by session_id) by the agent module.
  -- One row per (project, session). Refreshed incrementally on a schedule and
  -- on demand. journey is the ordered step list; flow_signature is the
  -- distinct-screen path used to group sessions into flows.
  CREATE TABLE IF NOT EXISTS app_sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id     INTEGER NOT NULL,
    session_id     TEXT NOT NULL,
    tracking_id    TEXT,                  -- UUID 1:1 với session_id, SDK stamp vào property của event Snowplow
    user_id        TEXT,
    platform       TEXT,
    app_version    TEXT,
    started_at     INTEGER,
    ended_at       INTEGER,
    ended_reason   TEXT,                  -- timeout | background_timeout | manual_reset | inferred_terminate | active
    duration_ms    INTEGER,
    event_count    INTEGER,
    screen_count   INTEGER,
    crashed        INTEGER DEFAULT 0,
    journey        TEXT,                  -- JSON: [{screen, event_name, element_key, ts}]
    flow_signature TEXT,                  -- "Home>List>Detail>Checkout"
    updated_at     INTEGER NOT NULL,
    UNIQUE(project_id, session_id)
  );

  -- Agent config: one row per project = the project's "root agent". Created
  -- automatically when a project is created. Holds the LLM endpoint + the two
  -- agent system prompts (analysis, report), the report schedule, and the
  -- delivery channels (Telegram, email). Secrets (llm_api_key, telegram_token)
  -- are masked when read back through the API.
  CREATE TABLE IF NOT EXISTS agent_config (
    project_id      INTEGER PRIMARY KEY,
    enabled         INTEGER DEFAULT 1,
    llm_endpoint    TEXT,
    llm_api_key     TEXT,
    llm_model       TEXT,
    analysis_prompt TEXT,
    report_prompt   TEXT,
    schedule_cron   TEXT DEFAULT '0 7 * * *',   -- ~once a day at 07:00
    telegram_token  TEXT,
    telegram_chat_id TEXT,
    email_app_dev    TEXT,                       -- recipient for app-category issues
    email_backend_dev TEXT,                      -- recipient for network/data/parse issues
    last_run_at     INTEGER,
    created_at      INTEGER NOT NULL
  );

  -- Agent reports: one row per analyze→report cycle the root agent runs.
  CREATE TABLE IF NOT EXISTS agent_reports (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id    INTEGER NOT NULL,
    created_at    INTEGER NOT NULL,
    period_start  INTEGER,
    period_end    INTEGER,
    analysis_json TEXT,                  -- raw output of the Analysis agent
    report_text   TEXT,                  -- formatted output of the Report agent
    category      TEXT,                  -- app | network | data | parse | mixed
    delivered     INTEGER DEFAULT 0,
    delivery_log  TEXT                   -- JSON: per-channel send result
  );

  -- Remote config: the app fetches this at startup instead of hardcoding its
  -- tracking setup. One row per project; each column is a JSON blob for a
  -- section of the config. version bumps on every save so the app/ETag can tell
  -- when to re-download.
  CREATE TABLE IF NOT EXISTS project_config (
    project_id     INTEGER PRIMARY KEY,
    endpoint       TEXT,                  -- UniTrack ingest endpoint
    sdk_config     TEXT,                  -- JSON: batchSize, flushIntervalMs, autoCapture flags, logLevel
    snowplow       TEXT,                  -- JSON: {enabled, endpoint, appId, userContext, userContextSchema, options, schemas}
    firebase       TEXT,                  -- JSON: {enabled, options:{apiKey,appId,projectId,gcmSenderId,bundleId,storageBucket}, superProperties, userProperties}
    tracing        TEXT,                  -- JSON: {enabled, header_name, allowlist_hosts:[...], sampled}
    http_providers TEXT,                  -- JSON: [{id, enabled, endpoint, format, headers, batch_size, flush_interval_ms}, ...]
    version        INTEGER NOT NULL DEFAULT 1,
    updated_at     INTEGER NOT NULL
  );

  -- Journey + tracking_id (đã loại bỏ): trước đây Portal giữ user-flow import
  -- từ Snowplow để debug. Sau khi SDK bỏ tracking_id, tính năng này không còn
  -- — schema cũ (journey_meta, journey_events, app_sessions.tracking_id) GIỮ
  -- LẠI ở production DB cho backward-compat nhưng KHÔNG được app/server ghi
  -- thêm dữ liệu mới. Có thể drop tay sau 1 vài release stable.
`);

// 2) Migrate pre-existing single-table databases: add any missing columns.
function ensureColumn(table, col, type) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all();
  if (!cols.some((c) => c.name === col)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${col} ${type}`);
  }
}
for (const [col, type] of [
  ['project_id', 'INTEGER'], ['session_id', 'TEXT'], ['user_id', 'TEXT'],
  ['screen', 'TEXT'], ['screen_name', 'TEXT'], ['class_name', 'TEXT'],
  ['element_key', 'TEXT'], ['platform', 'TEXT'], ['app_version', 'TEXT'],
  ['properties', 'TEXT'], ['device', 'TEXT'], ['source_ip', 'TEXT'],
  ['provider', "TEXT NOT NULL DEFAULT 'unitrack'"],
]) {
  ensureColumn('events', col, type);
}
ensureColumn('projects', 'owner_id', 'INTEGER');
ensureColumn('projects', 'sp_forward_url', 'TEXT');
ensureColumn('projects', 'providers', 'TEXT');
// JSON map { "HomeScreen": "Trang chủ", ... } — friendly screen labels shown
// in the portal (Sessions/wireframe) and searchable in the IDE.
ensureColumn('projects', 'screen_labels', 'TEXT');
ensureColumn('project_config', 'tracing', 'TEXT');
// http_providers (Phase 6) — JSON array of custom HTTP backends (Kibana / ELK
// / FPT internal). Portal là source of truth; SDK reconcile mỗi lần fetch.
ensureColumn('project_config', 'http_providers', 'TEXT');
// tracking_id (1:1 với session_id) — SDK 0.3.31/0.3.7+ stamp lên mọi event.
// QA dùng để query Snowplow ra full event timeline cho 1 session cụ thể.
ensureColumn('app_sessions', 'tracking_id', 'TEXT');

// Parked / dropped fields. SQLite 3.35+ supports DROP COLUMN; pre-3.35 just
// keeps the orphan column (harmless once code stops writing it).
function dropColumnIfExists(table, col) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all();
  if (cols.some((c) => c.name === col)) {
    try { db.exec(`ALTER TABLE ${table} DROP COLUMN ${col}`); }
    catch (_) { /* old SQLite — leave the column */ }
  }
}
dropColumnIfExists('project_config', 'event_registry');
// `rules` (Phase 2 rewrite rules) was superseded by the Snowplow convention
// layer — apps now call trackingClickEvent / trackingResultEvent / … directly
// instead of emitting a generic "tap" and renaming it on the wire.
dropColumnIfExists('project_config', 'rules');
// agent_config may predate the llm_model column (added when wiring the
// OpenAI-compatible endpoint). Add it to existing databases.
ensureColumn('agent_config', 'llm_model', 'TEXT');

// event_defs may predate the Snowplow-mapping columns. When set, an event def
// doubles as a forwarder config: the portal will relay any UniTrack event whose
// name matches def.name (or whose element_key maps to this def) to the project
// Snowplow collector, using sp_schema + sp_entities to build the tp2 payload.
//   sp_schema   — iglu URI (self-describing only). Required if sp_forward=1.
//   sp_forward  — 1 to relay to the project sp_forward_url, 0 to skip.
//   sp_entities — JSON array of entity names: ["user_context","core_action"].
//                 Each name resolves to a builder in snowplow.js that fills a
//                 SelfDescribingJson context from the event's device + user.
ensureColumn('event_defs', 'sp_schema',   'TEXT');
ensureColumn('event_defs', 'sp_forward',  'INTEGER DEFAULT 0');
ensureColumn('event_defs', 'sp_entities', 'TEXT');

// 3) Now the columns exist on every database — create the indexes.
db.exec(`
  CREATE INDEX IF NOT EXISTS idx_events_project  ON events(project_id);
  CREATE INDEX IF NOT EXISTS idx_events_name     ON events(event_name);
  CREATE INDEX IF NOT EXISTS idx_events_ts       ON events(timestamp);
  CREATE INDEX IF NOT EXISTS idx_events_session  ON events(session_id);
  CREATE INDEX IF NOT EXISTS idx_events_element  ON events(element_key);
  CREATE INDEX IF NOT EXISTS idx_events_provider ON events(provider);
  CREATE INDEX IF NOT EXISTS idx_app_sessions_project ON app_sessions(project_id);
  CREATE INDEX IF NOT EXISTS idx_app_sessions_flow    ON app_sessions(flow_signature);
  CREATE INDEX IF NOT EXISTS idx_agent_reports_project ON agent_reports(project_id);
`);

function newApiKey() {
  return 'utk_' + crypto.randomBytes(18).toString('base64url');
}

function newToken() {
  return crypto.randomBytes(32).toString('base64url');
}

// scrypt password hashing (built-in; no external bcrypt dependency).
function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}
function verifyPassword(password, stored) {
  const [salt, hash] = (stored || '').split(':');
  if (!salt || !hash) return false;
  const test = crypto.scryptSync(password, salt, 64).toString('hex');
  // constant-time compare
  const a = Buffer.from(hash, 'hex'), b = Buffer.from(test, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Seed an admin from env on first boot, and adopt any orphan projects.
(function seedAdmin() {
  const email = process.env.ADMIN_EMAIL;
  const pass = process.env.ADMIN_PASS;
  if (!email || !pass) return;
  const existing = db.prepare('SELECT id FROM users WHERE email = ?').get(email);
  let adminId;
  if (existing) {
    adminId = existing.id;
    // keep admin password in sync with env
    db.prepare('UPDATE users SET password_hash = ?, role = \'admin\' WHERE id = ?')
      .run(hashPassword(pass), adminId);
  } else {
    const info = db.prepare(
      'INSERT INTO users (email, password_hash, role, created_at) VALUES (?, ?, \'admin\', ?)'
    ).run(email, hashPassword(pass), Date.now());
    adminId = info.lastInsertRowid;
  }
  // Existing projects with no owner → give them to the admin.
  db.prepare('UPDATE projects SET owner_id = ? WHERE owner_id IS NULL').run(adminId);
})();

module.exports = { db, DB_PATH, newApiKey, newToken, hashPassword, verifyPassword };

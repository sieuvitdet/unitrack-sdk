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
    event_registry TEXT,                  -- JSON array: [{name, template, schema, forward}]
    rules          TEXT,                  -- JSON array: [{match_event,match_screen,match_element_key,to_name,add_props}]
    version        INTEGER NOT NULL DEFAULT 1,
    updated_at     INTEGER NOT NULL
  );
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
ensureColumn('project_config', 'rules', 'TEXT');

// 3) Now the columns exist on every database — create the indexes.
db.exec(`
  CREATE INDEX IF NOT EXISTS idx_events_project  ON events(project_id);
  CREATE INDEX IF NOT EXISTS idx_events_name     ON events(event_name);
  CREATE INDEX IF NOT EXISTS idx_events_ts       ON events(timestamp);
  CREATE INDEX IF NOT EXISTS idx_events_session  ON events(session_id);
  CREATE INDEX IF NOT EXISTS idx_events_element  ON events(element_key);
  CREATE INDEX IF NOT EXISTS idx_events_provider ON events(provider);
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

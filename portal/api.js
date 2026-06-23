// Portal JSON API: projects, events, event conventions, drag-drop mappings,
// stats, and Excel export. Mounted under {BASE}/api.

const express = require('express');
const zlib = require('zlib');
const { db, newApiKey } = require('./db');
const { buildWorkbook } = require('./export');
const { namingIssues, isValidName, healthScore } = require('./scoring');
const { requireAdmin } = require('./auth');
const { configForProject, saveConfig } = require('./config');
const { publishConfigChanged } = require('./config_stream');
const { reconstructSessions, computeFlows, computeFlowGraph, runCycle,
        DEFAULT_ANALYSIS_PROMPT, DEFAULT_REPORT_PROMPT } = require('./agent');
const { deliver } = require('./deliver');

// Ownership guard for project routes: admin can touch any project; a normal
// user only their own. Attaches req.project. Use as middleware on /projects/:id*.
function ownProject(req, res, next) {
  const p = db.prepare('SELECT * FROM projects WHERE id = ?').get(req.params.id);
  if (!p) return res.status(404).json({ error: 'not_found' });
  if (req.user.role !== 'admin' && p.owner_id !== req.user.id) {
    return res.status(403).json({ error: 'forbidden' });
  }
  req.project = p;
  next();
}

const router = express.Router();
const now = () => Date.now();
const parse = (s) => { try { return JSON.parse(s || '{}'); } catch { return {}; } };

// Reusable: compute the aggregates a project's health needs, then score it.
function projectHealth(pid) {
  const g = (sql, ...a) => db.prepare(sql).get(pid, ...a);
  const total = g('SELECT COUNT(*) n FROM events WHERE project_id=?').n;
  const sessions = g('SELECT COUNT(DISTINCT session_id) n FROM events WHERE project_id=?').n;
  const crashes = g("SELECT COUNT(*) n FROM events WHERE project_id=? AND event_name='crash'").n;
  const last = g('SELECT MAX(received_at) t FROM events WHERE project_id=?').t;
  const byEvent = db.prepare('SELECT event_name, COUNT(*) count FROM events WHERE project_id=? GROUP BY event_name').all(pid);
  const elementsTotal = g("SELECT COUNT(DISTINCT element_key) n FROM events WHERE project_id=? AND element_key IS NOT NULL AND element_key<>''").n;
  const elementsDefined = g('SELECT COUNT(DISTINCT element_key) n FROM event_mappings WHERE project_id=?').n;
  return healthScore({
    total, sessions, crashes, byEvent,
    elementsTotal, elementsDefined, lastReceivedAt: last,
  });
}

// ---------------------------------------------------------------- projects
// A user sees only their projects; an admin sees all.
router.get('/projects', (req, res) => {
  const admin = req.user.role === 'admin';
  const rows = db.prepare(`
    SELECT p.*, (SELECT COUNT(*) FROM events e WHERE e.project_id = p.id) AS event_count
    FROM projects p ${admin ? '' : 'WHERE p.owner_id = ?'} ORDER BY p.created_at DESC
  `).all(...(admin ? [] : [req.user.id]));
  res.json(rows);
});

router.post('/projects', (req, res) => {
  const { name, app_bundle, source_type } = req.body || {};
  if (!name) return res.status(400).json({ error: 'name_required' });
  const info = db.prepare(`
    INSERT INTO projects (owner_id, name, app_bundle, source_type, api_key, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(req.user.id, name, app_bundle ?? null, source_type ?? null, newApiKey(), now());
  // Auto-create the project's "root agent": one agent_config row with the two
  // default system prompts, disabled delivery until the user fills in the LLM
  // endpoint + Telegram/email. enabled=1 so the schedule picks it up once
  // configured. This is requirement #1 ("tạo project → sinh root agent").
  db.prepare(`
    INSERT INTO agent_config (project_id, enabled, analysis_prompt, report_prompt, schedule_cron, created_at)
    VALUES (?, 1, ?, ?, '0 7 * * *', ?)
  `).run(info.lastInsertRowid, DEFAULT_ANALYSIS_PROMPT, DEFAULT_REPORT_PROMPT, now());
  res.json(db.prepare('SELECT * FROM projects WHERE id = ?').get(info.lastInsertRowid));
});

router.get('/projects/:id', ownProject, (req, res) => {
  res.json(req.project);
});

router.delete('/projects/:id', ownProject, (req, res) => {
  db.prepare('DELETE FROM projects WHERE id = ?').run(req.params.id);
  res.json({ ok: true });
});

router.post('/projects/:id/rotate-key', ownProject, (req, res) => {
  const key = newApiKey();
  db.prepare('UPDATE projects SET api_key = ? WHERE id = ?').run(key, req.params.id);
  res.json({ api_key: key });
});

// Provider settings: which providers this project forwards to, and (for the
// Snowplow proxy) the real collector URL to relay events to. Blank URL = the
// portal is the only sink (collect-only).
router.put('/projects/:id/providers', ownProject, (req, res) => {
  const body = req.body || {};
  const list = Array.isArray(body.providers)
    ? body.providers.filter((p) => ['snowplow', 'firebase'].includes(p))
    : [];
  // Portal UI tab Config bỏ ô "Portal mirror" → client KHÔNG gửi key này nữa.
  // Khi key vắng mặt, giữ nguyên value DB hiện tại (backward-compat cho
  // project cũ đã cấu hình sp_forward_url qua API import / cURL).
  if ('sp_forward_url' in body) {
    db.prepare('UPDATE projects SET providers = ?, sp_forward_url = ? WHERE id = ?')
      .run(JSON.stringify(list), body.sp_forward_url || null, req.params.id);
  } else {
    db.prepare('UPDATE projects SET providers = ? WHERE id = ?')
      .run(JSON.stringify(list), req.params.id);
  }
  res.json(db.prepare('SELECT * FROM projects WHERE id = ?').get(req.params.id));
});

// Friendly screen-name labels (JSON map class→Vietnamese). Shown across the
// portal and searchable in the session IDE. GET returns {} if none set.
router.get('/projects/:id/screen-labels', ownProject, (req, res) => {
  let map = {};
  try { map = JSON.parse(req.project.screen_labels || '{}') || {}; } catch (_) { map = {}; }
  res.json({ labels: map });
});
router.put('/projects/:id/screen-labels', ownProject, (req, res) => {
  const body = req.body || {};
  // Accept either {labels:{...}} or a bare {...} map. Keep only string→string.
  const raw = body.labels && typeof body.labels === 'object' ? body.labels : body;
  const map = {};
  if (raw && typeof raw === 'object') {
    for (const [k, v] of Object.entries(raw)) {
      if (typeof k === 'string' && k && v != null) map[k] = String(v);
    }
  }
  db.prepare('UPDATE projects SET screen_labels = ? WHERE id = ?')
    .run(JSON.stringify(map), req.params.id);
  res.json({ labels: map });
});

// Remote config: the editor reads the full resolved config; PUT saves any subset
// of sections and bumps the version (the app re-downloads when version changes).
router.get('/projects/:id/config', ownProject, (req, res) => {
  res.json(configForProject(req.project));
});

router.put('/projects/:id/config', ownProject, (req, res) => {
  const pid = Number(req.params.id);
  const version = saveConfig(pid, req.body || {});
  // Push the new version to every SDK currently watching this project's SSE
  // stream so foreground apps refresh without waiting for their throttled
  // poll. Fire-and-forget — broadcast doesn't await any client write.
  publishConfigChanged(pid, version);
  res.json({ ...configForProject(req.project), version });
});

// Export the entire project config (plus Snowplow event maps) as a portable
// JSON bundle. The intent is to mirror config across projects — copy a known-
// good camera setup over to a brand-new Flutter/RN/whatever project without
// re-clicking through every screen on the portal. Bundle deliberately drops
// project-scoped bits (id, name, version, updated_at, flavor) so import is
// just "apply these settings to the target project".
router.get('/projects/:id/config/export', ownProject, (req, res) => {
  const cfg = configForProject(req.project);
  const spMaps = db.prepare(`
    SELECT event_name, mode, schema, forward
      FROM sp_event_maps WHERE project_id = ? ORDER BY event_name
  `).all(req.project.id);
  const bundle = {
    bundle_kind: 'unitrack_project_config',
    bundle_version: 1,
    exported_at: Date.now(),
    exported_from: { project_id: req.project.id, name: req.project.name },
    config: {
      endpoint:       cfg.endpoint || null,
      sdk_config:     cfg.sdk_config || {},
      snowplow:       cfg.snowplow || {},
      firebase:       cfg.firebase || {},
      tracing:        cfg.tracing || {},
      http_providers: cfg.http_providers || [],
    },
    sp_event_maps: spMaps,
  };
  const filename = `unitrack-config-${req.project.name || req.project.id}-v${cfg.version}.json`
    .replace(/[^a-z0-9._\-]+/gi, '_');
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${filename}"`);
  res.send(JSON.stringify(bundle, null, 2));
});

// Import a previously-exported bundle into THIS project. Accepts the same
// shape /export emits. Body must be the parsed JSON; the SPA can either send
// it directly (FileReader → JSON.parse → POST) or paste it into a textarea.
// Refuses obviously-wrong shapes so a wrong file doesn't quietly clobber a
// project. The import REPLACES the matching sections (subset semantics —
// keys NOT present in the bundle are left untouched, same as PUT /config).
router.post('/projects/:id/config/import', ownProject, (req, res) => {
  const body = req.body || {};
  if (body.bundle_kind !== 'unitrack_project_config') {
    return res.status(400).json({ error: 'wrong_bundle_kind',
      hint: 'expected bundle_kind="unitrack_project_config"' });
  }
  if (body.bundle_version !== 1) {
    return res.status(400).json({ error: 'unsupported_bundle_version',
      bundle_version: body.bundle_version, supported: [1] });
  }
  const c = body.config || {};
  // Pass each section through saveConfig only if the bundle actually has it
  // — otherwise the existing value stays. JSON-stringify happens inside.
  const patch = {};
  if (c.endpoint       !== undefined) patch.endpoint       = c.endpoint;
  if (c.sdk_config     !== undefined) patch.sdk_config     = c.sdk_config;
  if (c.snowplow       !== undefined) patch.snowplow       = c.snowplow;
  if (c.firebase       !== undefined) patch.firebase       = c.firebase;
  if (c.tracing        !== undefined) patch.tracing        = c.tracing;
  if (c.http_providers !== undefined) patch.http_providers = c.http_providers;
  const version = saveConfig(Number(req.params.id), patch);

  // sp_event_maps: clear + repopulate. These are small and the natural mental
  // model is "the bundle's maps replace this project's maps", same as a paste
  // would on the UI. Keep partial bundles working — only touch if present.
  let spMapsImported = 0;
  if (Array.isArray(body.sp_event_maps)) {
    db.prepare('DELETE FROM sp_event_maps WHERE project_id = ?').run(req.project.id);
    const ins = db.prepare(`
      INSERT INTO sp_event_maps (project_id, event_name, mode, schema, forward, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `);
    const now = Date.now();
    for (const m of body.sp_event_maps) {
      if (!m || !m.event_name) continue;
      const mode = (m.mode === 'structured') ? 'structured' : 'self_describing';
      ins.run(req.project.id, m.event_name, mode, m.schema || null,
              m.forward ? 1 : 0, now);
      spMapsImported++;
    }
  }
  res.json({
    ok: true,
    version,
    imported: {
      sections: Object.keys(patch),
      sp_event_maps: spMapsImported,
    },
    config: configForProject(req.project),
  });
});

// Snowplow event mappings: raw event name → Snowplow schema/mode + forward flag.
// Lets you onboard a NEW Snowplow event by adding a row here (no app rebuild).
router.get('/projects/:id/sp-maps', ownProject, (req, res) => {
  res.json(db.prepare('SELECT * FROM sp_event_maps WHERE project_id = ? ORDER BY event_name')
    .all(req.params.id));
});

router.post('/projects/:id/sp-maps', ownProject, (req, res) => {
  const { event_name, mode, schema, forward } = req.body || {};
  if (!event_name) return res.status(400).json({ error: 'event_name_required' });
  const m = (mode === 'structured') ? 'structured' : 'self_describing';
  if (m === 'self_describing' && !schema) return res.status(400).json({ error: 'schema_required' });
  try {
    db.prepare(`
      INSERT INTO sp_event_maps (project_id, event_name, mode, schema, forward, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(project_id, event_name) DO UPDATE SET
        mode = excluded.mode, schema = excluded.schema, forward = excluded.forward
    `).run(req.params.id, event_name, m, schema || null, forward === false ? 0 : 1, now());
    res.json(db.prepare('SELECT * FROM sp_event_maps WHERE project_id = ? AND event_name = ?')
      .get(req.params.id, event_name));
  } catch (e) {
    res.status(500).json({ error: 'save_failed' });
  }
});

router.delete('/projects/:id/sp-maps/:name', ownProject, (req, res) => {
  db.prepare('DELETE FROM sp_event_maps WHERE project_id = ? AND event_name = ?')
    .run(req.params.id, req.params.name);
  res.json({ ok: true });
});

// ----------------------------------------------------------------- events
router.get('/projects/:id/events', ownProject, (req, res) => {
  const pid = req.params.id;
  const limit = Math.min(parseInt(req.query.limit, 10) || 200, 2000);
  const where = ['project_id = ?'];
  const args = [pid];
  if (req.query.name)     { where.push('event_name = ?'); args.push(req.query.name); }
  if (req.query.session)  { where.push('session_id = ?'); args.push(req.query.session); }
  if (req.query.provider) { where.push('provider = ?');   args.push(req.query.provider); }
  if (req.query.q) {
    // Search across stable identifiers + the raw properties blob so users
    // can paste a trace_id / span_id / arbitrary prop value and find it.
    // properties is TEXT-encoded JSON in SQLite — LIKE works on the raw
    // string, no schema-aware extraction needed.
    where.push('(event_name LIKE ? OR screen_name LIKE ? OR class_name LIKE ? OR element_key LIKE ? OR properties LIKE ?)');
    const k = `%${req.query.q}%`; args.push(k, k, k, k, k);
  }
  args.push(limit);
  const rows = db.prepare(`
    SELECT * FROM events WHERE ${where.join(' AND ')} ORDER BY id DESC LIMIT ?
  `).all(...args);

  // Resolve the convention each event's element maps to (drag-and-drop), so the
  // log can show "tap → product_add_to_card". One lookup for the whole page.
  const maps = db.prepare(`
    SELECT m.element_key, d.name AS def_name
    FROM event_mappings m JOIN event_defs d ON d.id = m.event_def_id
    WHERE m.project_id = ?
  `).all(pid);
  const mappedName = Object.fromEntries(maps.map((m) => [m.element_key, m.def_name]));

  res.json(rows.map((r) => ({
    ...r,
    properties: parse(r.properties),
    device: r.device ? parse(r.device) : null,
    mapped_event: r.element_key ? (mappedName[r.element_key] || null) : null,
  })));
});

// Tap elements grouped, split into defined (mapped to a convention) vs not.
router.get('/projects/:id/elements', ownProject, (req, res) => {
  const pid = req.params.id;
  const rows = db.prepare(`
    SELECT element_key,
           MAX(screen_name) AS screen_name,
           MAX(class_name)  AS class_name,
           COUNT(*)         AS hits,
           MAX(timestamp)   AS last_seen
    FROM events
    WHERE project_id = ? AND element_key IS NOT NULL AND element_key <> ''
    GROUP BY element_key
    ORDER BY hits DESC
  `).all(pid);

  const maps = db.prepare(`
    SELECT m.element_key, d.id AS def_id, d.name AS def_name
    FROM event_mappings m JOIN event_defs d ON d.id = m.event_def_id
    WHERE m.project_id = ?
  `).all(pid);
  const byKey = Object.fromEntries(maps.map((m) => [m.element_key, m]));

  const defined = [], undefined_ = [];
  for (const r of rows) {
    const map = byKey[r.element_key];
    if (map) defined.push({ ...r, event_def: { id: map.def_id, name: map.def_name } });
    else undefined_.push(r);
  }
  res.json({ defined, undefined: undefined_ });
});

// ----------------------------------------------------- event conventions
router.get('/projects/:id/defs', ownProject, (req, res) => {
  res.json(db.prepare('SELECT * FROM event_defs WHERE project_id = ? ORDER BY name').all(req.params.id));
});

// Create OR update an event_def by name (upsert). Body may include the
// Snowplow forwarder fields — leave them blank to keep the def as a pure
// "name a UniTrack event" record, or fill them in to also relay this event
// (or every element_key mapped to it) to the project Snowplow collector.
//   sp_schema   — iglu URI, required when sp_forward is true
//   sp_forward  — boolean, default false
//   sp_entities — string[] of entity builder names (e.g. ["user_context"])
router.post('/projects/:id/defs', ownProject, (req, res) => {
  const { name, description, sp_schema, sp_forward, sp_entities } = req.body || {};
  if (!name) return res.status(400).json({ error: 'name_required' });
  if (sp_forward && !sp_schema) {
    return res.status(400).json({ error: 'sp_schema_required_when_forwarding' });
  }
  const entitiesJson = Array.isArray(sp_entities)
    ? JSON.stringify(sp_entities.filter((s) => typeof s === 'string'))
    : null;
  try {
    db.prepare(`
      INSERT INTO event_defs (project_id, name, description, sp_schema, sp_forward, sp_entities, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(project_id, name) DO UPDATE SET
        description = excluded.description,
        sp_schema   = excluded.sp_schema,
        sp_forward  = excluded.sp_forward,
        sp_entities = excluded.sp_entities
    `).run(
      req.params.id, name, description ?? null,
      sp_schema || null, sp_forward ? 1 : 0, entitiesJson,
      now()
    );
    res.json(db.prepare('SELECT * FROM event_defs WHERE project_id = ? AND name = ?')
      .get(req.params.id, name));
  } catch (e) {
    res.status(500).json({ error: 'save_failed', detail: e.message });
  }
});

// Update Snowplow-mapping fields on an existing def by id. Description and
// rename are not supported here on purpose — POST upsert handles those.
router.patch('/defs/:defId', (req, res) => {
  const def = db.prepare('SELECT d.id, d.name, p.owner_id, p.id AS project_id FROM event_defs d JOIN projects p ON p.id = d.project_id WHERE d.id = ?').get(req.params.defId);
  if (!def) return res.status(404).json({ error: 'not_found' });
  if (req.user.role !== 'admin' && def.owner_id !== req.user.id) {
    return res.status(403).json({ error: 'forbidden' });
  }
  const { sp_schema, sp_forward, sp_entities } = req.body || {};
  if (sp_forward && !sp_schema) {
    return res.status(400).json({ error: 'sp_schema_required_when_forwarding' });
  }
  const entitiesJson = Array.isArray(sp_entities)
    ? JSON.stringify(sp_entities.filter((s) => typeof s === 'string'))
    : null;
  db.prepare(`
    UPDATE event_defs SET sp_schema = ?, sp_forward = ?, sp_entities = ? WHERE id = ?
  `).run(sp_schema || null, sp_forward ? 1 : 0, entitiesJson, req.params.defId);
  res.json(db.prepare('SELECT * FROM event_defs WHERE id = ?').get(req.params.defId));
});

router.delete('/defs/:defId', (req, res) => {
  // Verify the def belongs to a project the user owns (or user is admin).
  const def = db.prepare('SELECT d.id, p.owner_id FROM event_defs d JOIN projects p ON p.id = d.project_id WHERE d.id = ?').get(req.params.defId);
  if (!def) return res.status(404).json({ error: 'not_found' });
  if (req.user.role !== 'admin' && def.owner_id !== req.user.id) {
    return res.status(403).json({ error: 'forbidden' });
  }
  db.prepare('DELETE FROM event_mappings WHERE event_def_id = ?').run(req.params.defId);
  db.prepare('DELETE FROM event_defs WHERE id = ?').run(req.params.defId);
  res.json({ ok: true });
});

// --------------------------------------------- drag-and-drop mappings
router.post('/projects/:id/mappings', ownProject, (req, res) => {
  const { element_key, event_def_id } = req.body || {};
  if (!element_key || !event_def_id) return res.status(400).json({ error: 'bad_request' });
  db.prepare(`
    INSERT INTO event_mappings (project_id, element_key, event_def_id, created_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(project_id, element_key)
    DO UPDATE SET event_def_id = excluded.event_def_id
  `).run(req.params.id, element_key, event_def_id, now());
  res.json({ ok: true });
});

router.delete('/projects/:id/mappings/:elementKey', ownProject, (req, res) => {
  db.prepare('DELETE FROM event_mappings WHERE project_id = ? AND element_key = ?')
    .run(req.params.id, req.params.elementKey);
  res.json({ ok: true });
});

// ------------------------------------------------------------------ stats
router.get('/projects/:id/stats', ownProject, (req, res) => {
  const pid = req.params.id;
  const one = (sql, ...a) => db.prepare(sql).get(pid, ...a);
  const all = (sql, ...a) => db.prepare(sql).all(pid, ...a);

  // Detect the REAL app bundle(s) from the device payload of recent events.
  // This is what the SDK actually reported (e.g. com.example.app), as opposed
  // to the project's app_bundle label which is typed in by hand at creation.
  const counts = new Map();
  for (const r of all(
    'SELECT device FROM events WHERE project_id = ? AND device IS NOT NULL ORDER BY received_at DESC LIMIT 500'
  )) {
    let b = null;
    try { const d = JSON.parse(r.device); b = d.bundle_id || d.bundle || d.package || d.app_id || null; }
    catch (_) { /* malformed device json — skip */ }
    if (b) counts.set(b, (counts.get(b) || 0) + 1);
  }
  const detected_bundles = [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([bundle, count]) => ({ bundle, count }));

  res.json({
    detected_bundles,
    total:    one('SELECT COUNT(*) n FROM events WHERE project_id = ?').n,
    sessions: one('SELECT COUNT(DISTINCT session_id) n FROM events WHERE project_id = ?').n,
    // Skip BOTH null AND empty-string user_id values — pre-login events fan
    // out with user_id="" which used to inflate the count (5 instead of 4).
    users:    one("SELECT COUNT(DISTINCT user_id) n FROM events WHERE project_id = ? AND user_id IS NOT NULL AND user_id <> ''").n,
    last_hour: one('SELECT COUNT(*) n FROM events WHERE project_id = ? AND received_at > ?', now() - 3600_000).n,
    by_event:    all('SELECT event_name, COUNT(*) count FROM events WHERE project_id = ? GROUP BY event_name ORDER BY count DESC'),
    by_platform: all("SELECT COALESCE(platform,'unknown') platform, COUNT(*) count FROM events WHERE project_id = ? GROUP BY platform ORDER BY count DESC"),
    by_screen:   all("SELECT COALESCE(screen_name,'unknown') screen, COUNT(*) count FROM events WHERE project_id = ? GROUP BY screen_name ORDER BY count DESC LIMIT 20"),
    crashes:     one("SELECT COUNT(*) n FROM events WHERE project_id = ? AND event_name = 'crash'").n,
  });
});

// Daily time-series for the report charts on the project overview.
// Returns three parallel arrays bucketed by day (TZ-naive UTC; the SPA
// renders the date label in the user's locale). Days with no activity
// emit a 0 so the area chart draws a continuous baseline.
//
// Query knobs:
//   ?days=N          window length (default 7, hard-capped at 90 so a typo
//                    can't ask for years of buckets)
//
// Shape:
//   { range_days, buckets: [{ day:"2026-05-31",
//                              users, sessions, crashes,
//                              crash_per_session_pct }] }
router.get('/projects/:id/stats-series', ownProject, (req, res) => {
  const pid = req.params.id;
  const days = Math.max(1, Math.min(90, parseInt(req.query.days, 10) || 7));
  const now = Date.now();
  const dayMs = 86_400_000;
  // Anchor to UTC midnight of "today" so buckets line up day-by-day
  // regardless of when the query fires within the day.
  const todayUtc = Math.floor(now / dayMs) * dayMs;
  const start = todayUtc - (days - 1) * dayMs;

  // SQL bucketing: SQLite has strftime('%Y-%m-%d', ts/1000, 'unixepoch'),
  // but a 7-day series with COUNT(DISTINCT user_id) per bucket is faster as
  // ONE scan with a CASE-WHEN GROUP BY day-index. The day index = floor((ts -
  // start) / 86400000) which sqlite computes natively.
  //
  // crashed_sessions = COUNT(DISTINCT session_id) WHERE event_name='crash' —
  // counts a session at most once even if it crashed multiple times. That's
  // the metric the operator actually wants: "% sessions hit a crash" stays
  // in 0-100% range, unlike crashes/sessions which spikes to 800% when one
  // bad day fires 30 crashes per session.
  const series = db.prepare(`
    SELECT CAST((timestamp - ?) / ? AS INTEGER)                                     AS day_idx,
           COUNT(DISTINCT user_id)                                                  AS users,
           COUNT(DISTINCT session_id)                                               AS sessions,
           SUM(CASE WHEN event_name='crash' THEN 1 ELSE 0 END)                      AS crashes,
           COUNT(DISTINCT CASE WHEN event_name='crash' THEN session_id END)         AS crashed_sessions
    FROM events
    WHERE project_id = ?
      AND timestamp >= ?
      AND timestamp <  ?
      AND user_id IS NOT NULL AND user_id <> ''
    GROUP BY day_idx
    ORDER BY day_idx ASC
  `).all(start, dayMs, pid, start, todayUtc + dayMs);

  // Fold the SQL result into a dense array (one entry per day in range).
  // Missing days stay at 0 so the chart line touches the baseline instead
  // of skipping x positions.
  const buckets = [];
  for (let i = 0; i < days; i++) {
    const dayStart = start + i * dayMs;
    const found = series.find((r) => r.day_idx === i);
    const users           = found ? (found.users            || 0) : 0;
    const sessions        = found ? (found.sessions         || 0) : 0;
    const crashes         = found ? (found.crashes          || 0) : 0;
    const crashedSessions = found ? (found.crashed_sessions || 0) : 0;
    buckets.push({
      day:     new Date(dayStart).toISOString().slice(0, 10), // "2026-05-31"
      day_ms:  dayStart,
      users, sessions, crashes,
      crashed_sessions: crashedSessions,
      // % of sessions that hit at least one crash — capped naturally at 100%.
      crash_per_session_pct: sessions
        ? Math.round((crashedSessions / sessions) * 1000) / 10
        : 0,
    });
  }

  // ETag from the freshest event we counted — invalidate as soon as ingest
  // adds anything in-window.
  const maxTs = db.prepare(
    'SELECT MAX(timestamp) m FROM events WHERE project_id = ? AND timestamp >= ?'
  ).get(pid, start)?.m || 0;
  const etag = `"series-${pid}-${days}-${maxTs}"`;
  if (req.headers['if-none-match'] === etag) {
    res.set('ETag', etag);
    res.set('Cache-Control', 'private, max-age=30');
    return res.status(304).end();
  }
  res.set('ETag', etag);
  res.set('Cache-Control', 'private, max-age=30');
  res.json({ range_days: days, buckets });
});

// Crash report: every crash event grouped by signature (message + screen) so
// the operator can see "8 sessions hit the same NPE on RemainingShiftScreen".
// Each group carries: count, distinct sessions/users, first/last seen, one
// representative crash (with stack trace), and the most recent 5 sessions
// hit so the SPA can deep-link straight into the session IDE.
router.get('/projects/:id/crashes', ownProject, (req, res) => {
  const pid = req.params.id;
  const rows = db.prepare(`
    SELECT id, event_id, timestamp, session_id, user_id,
           screen_name, screen, class_name, platform, app_version, properties
    FROM events
    WHERE project_id = ? AND event_name = 'crash'
    ORDER BY timestamp DESC
  `).all(pid);

  // Build a fingerprint per crash: message + screen. Stack-trace top frame
  // would be more precise but the SDK doesn't always carry one (Flutter
  // exceptions vs native signals carry different shapes). Message + screen is
  // a good signal for "same bug" in practice.
  const groups = new Map();
  // Trim the bug message so different exception instances with the same root
  // cause collapse into one group ("FormatException: Invalid number 5", "...8").
  const trimMessage = (m) => {
    if (!m) return '(unknown)';
    let s = String(m).split('\n')[0];     // first line only
    if (s.length > 140) s = s.slice(0, 137) + '…';
    return s;
  };

  for (const r of rows) {
    let props = {}; try { props = JSON.parse(r.properties || '{}'); } catch (_) {}
    const message = trimMessage(props.message || props.error || props.exception || props.signal_name);
    const screen  = r.screen_name || r.screen || props.screen || props.screen_name || '(unknown)';
    const key = `${screen}|${message}`;
    let g = groups.get(key);
    if (!g) {
      g = {
        signature: key,
        message,
        screen,
        count: 0,
        sessions: new Set(),
        users: new Set(),
        first_seen: r.timestamp,
        last_seen:  r.timestamp,
        // Keep the most-recent representative so the dialog has stack+props ready.
        sample: {
          event_id:    r.event_id,
          timestamp:   r.timestamp,
          session_id:  r.session_id,
          user_id:     r.user_id,
          platform:    r.platform,
          app_version: r.app_version,
          class_name:  r.class_name,
          properties:  props,
        },
        recent_sessions: [],   // unique session_ids, newest first
      };
      groups.set(key, g);
    }
    g.count++;
    if (r.session_id) g.sessions.add(r.session_id);
    if (r.user_id)    g.users.add(r.user_id);
    g.first_seen = Math.min(g.first_seen, r.timestamp);
    g.last_seen  = Math.max(g.last_seen,  r.timestamp);
    if (r.session_id && !g.recent_sessions.find((s) => s.session_id === r.session_id) && g.recent_sessions.length < 5) {
      g.recent_sessions.push({
        session_id:  r.session_id,
        user_id:     r.user_id,
        timestamp:   r.timestamp,
        app_version: r.app_version,
      });
    }
  }

  const out = [...groups.values()]
    .map((g) => ({
      signature:        g.signature,
      message:          g.message,
      screen:           g.screen,
      count:            g.count,
      session_count:    g.sessions.size,
      user_count:       g.users.size,
      first_seen:       g.first_seen,
      last_seen:        g.last_seen,
      sample:           g.sample,
      recent_sessions:  g.recent_sessions,
    }))
    .sort((a, b) => b.count - a.count);   // most frequent first

  res.json({
    total_crashes: rows.length,
    group_count:   out.length,
    groups:        out,
  });
});

// ----------------------------------------------------------------- users
// Identified users for a project: id + traits (from the latest `identify`
// event's properties, e.g. username/epcode) + session/event counts + last seen.
router.get('/projects/:id/users', ownProject, (req, res) => {
  const pid = req.params.id;
  const rows = db.prepare(`
    SELECT user_id,
           COUNT(*)                      AS event_count,
           COUNT(DISTINCT session_id)    AS session_count,
           MIN(timestamp)                AS first_seen,
           MAX(timestamp)                AS last_seen,
           MAX(CASE WHEN event_name='identify' THEN properties END) AS traits_json
    FROM events
    WHERE project_id = ? AND user_id IS NOT NULL AND user_id <> ''
    GROUP BY user_id
    ORDER BY last_seen DESC
  `).all(pid);
  const users = rows.map((r) => {
    let traits = {};
    try { traits = JSON.parse(r.traits_json || '{}') || {}; } catch (_) { traits = {}; }
    // The identify payload wraps traits under "traits" on some platforms; flatten.
    if (traits.traits && typeof traits.traits === 'object') traits = { ...traits, ...traits.traits };
    delete traits.traits;
    return {
      user_id: r.user_id,
      username: traits.username || traits.user_name || r.user_id,
      epcode: traits.epcode || traits.epCode || null,
      traits,
      session_count: r.session_count,
      event_count: r.event_count,
      first_seen: r.first_seen,
      last_seen: r.last_seen,
    };
  });
  res.json({ users });
});

// --------------------------------------------------------------- sessions
// List reconstructed sessions (newest first). Refreshes the materialized
// app_sessions view from the raw events stream before returning, so the
// timeline reflects events that arrived since the last view. Optional ?user=
// filters to one user's sessions.
router.get('/projects/:id/sessions', ownProject, (req, res) => {
  const pid = req.params.id;
  let reconstruct_failed = false;
  try { reconstructSessions(pid); }
  catch (err) { reconstruct_failed = true; console.error('[sessions] reconstruct failed', err); }
  const user = (req.query.user || '').trim();   // optional filter by user_id

  // ETag is built from the freshest watermark in app_sessions (max updated_at
  // and row count) + the user filter. Same response shape → same ETag, so a
  // browser revisit on the Sessions tab gets a 304 without us reading 500
  // rows + JSON-stringifying ~24 journeys.
  const wm = user
    ? db.prepare(`SELECT MAX(updated_at) u, COUNT(*) c
                  FROM app_sessions WHERE project_id = ? AND user_id = ?`).get(pid, user)
    : db.prepare(`SELECT MAX(updated_at) u, COUNT(*) c
                  FROM app_sessions WHERE project_id = ?`).get(pid);
  const etag = `"sess-${pid}-${user || 'all'}-${wm.c || 0}-${wm.u || 0}"`;
  if (req.headers['if-none-match'] === etag) {
    res.set('ETag', etag);
    res.set('Cache-Control', 'private, max-age=10');
    return res.status(304).end();
  }

  const rows = user
    ? db.prepare(`
        SELECT id, session_id, tracking_id, user_id, platform, app_version, started_at, ended_at,
               ended_reason, duration_ms, event_count, screen_count, crashed, flow_signature
        FROM app_sessions WHERE project_id = ? AND user_id = ?
        ORDER BY started_at DESC LIMIT 500`).all(pid, user)
    : db.prepare(`
        SELECT id, session_id, tracking_id, user_id, platform, app_version, started_at, ended_at,
               ended_reason, duration_ms, event_count, screen_count, crashed, flow_signature
        FROM app_sessions WHERE project_id = ?
        ORDER BY started_at DESC LIMIT 500`).all(pid);
  res.set('ETag', etag);
  // 10s browser cache; the SPA still revalidates via if-none-match so a
  // new session showing up clears the 304 instantly.
  res.set('Cache-Control', 'private, max-age=10');
  // Surface reconstruction failure so the client knows the list may be stale,
  // rather than silently returning old data with a 200.
  res.json({ reconstructed_at: Date.now(), reconstruct_failed, sessions: rows });
});

// Flow analytics: usage + crash/stuck rate per flow (Phase 2, heuristic).
router.get('/projects/:id/flows', ownProject, (req, res) => {
  try { res.json(computeFlows(req.params.id)); }
  catch (err) { console.error('[flows] failed', err); res.status(500).json({ error: 'flows_failed' }); }
});

// Wireframe flow graph: screen nodes + transition edges with heatmap metrics.
router.get('/projects/:id/flowgraph', ownProject, (req, res) => {
  const userId = (req.query.user || '').trim() || null;
  try { res.json(computeFlowGraph(req.params.id, { userId })); }
  catch (err) { console.error('[flowgraph] failed', err); res.status(500).json({ error: 'flowgraph_failed' }); }
});

// ---------------------------------------------------------------- agent
// Mask a secret for read-back: show only that it's set, never the value.
const maskSecret = (v) => (v ? '••••••' + String(v).slice(-4) : '');

// Read the project's root-agent config. Secrets are masked.
router.get('/projects/:id/agent', ownProject, (req, res) => {
  let cfg = db.prepare('SELECT * FROM agent_config WHERE project_id = ?').get(req.params.id);
  if (!cfg) {
    // Self-heal for projects created before agent_config existed.
    db.prepare(`INSERT INTO agent_config (project_id, enabled, analysis_prompt, report_prompt, schedule_cron, created_at)
                VALUES (?, 1, ?, ?, '0 7 * * *', ?)`)
      .run(req.params.id, DEFAULT_ANALYSIS_PROMPT, DEFAULT_REPORT_PROMPT, now());
    cfg = db.prepare('SELECT * FROM agent_config WHERE project_id = ?').get(req.params.id);
  }
  res.json({
    ...cfg,
    llm_api_key:    maskSecret(cfg.llm_api_key),
    telegram_token: maskSecret(cfg.telegram_token),
    has_llm_api_key:    !!cfg.llm_api_key,
    has_telegram_token: !!cfg.telegram_token,
  });
});

// Update the root-agent config. A masked/blank secret means "keep existing" so
// editing other fields doesn't wipe the stored token.
router.put('/projects/:id/agent', ownProject, (req, res) => {
  const pid = req.params.id;
  const cur = db.prepare('SELECT * FROM agent_config WHERE project_id = ?').get(pid) || {};
  const b = req.body || {};
  const keepSecret = (incoming, existing) =>
    (incoming === undefined || incoming === '' || /^••••••/.test(incoming)) ? existing : incoming;

  db.prepare(`
    INSERT INTO agent_config
      (project_id, enabled, llm_endpoint, llm_api_key, llm_model, analysis_prompt, report_prompt,
       schedule_cron, telegram_token, telegram_chat_id, email_app_dev, email_backend_dev, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(project_id) DO UPDATE SET
      enabled = excluded.enabled, llm_endpoint = excluded.llm_endpoint,
      llm_api_key = excluded.llm_api_key, llm_model = excluded.llm_model,
      analysis_prompt = excluded.analysis_prompt,
      report_prompt = excluded.report_prompt, schedule_cron = excluded.schedule_cron,
      telegram_token = excluded.telegram_token, telegram_chat_id = excluded.telegram_chat_id,
      email_app_dev = excluded.email_app_dev, email_backend_dev = excluded.email_backend_dev
  `).run(
    pid,
    b.enabled !== undefined ? (b.enabled ? 1 : 0) : (cur.enabled ?? 1),
    b.llm_endpoint    ?? cur.llm_endpoint ?? null,
    keepSecret(b.llm_api_key, cur.llm_api_key ?? null),
    b.llm_model       ?? cur.llm_model ?? null,
    b.analysis_prompt ?? cur.analysis_prompt ?? DEFAULT_ANALYSIS_PROMPT,
    b.report_prompt   ?? cur.report_prompt ?? DEFAULT_REPORT_PROMPT,
    b.schedule_cron   ?? cur.schedule_cron ?? '0 7 * * *',
    keepSecret(b.telegram_token, cur.telegram_token ?? null),
    b.telegram_chat_id  ?? cur.telegram_chat_id ?? null,
    b.email_app_dev     ?? cur.email_app_dev ?? null,
    b.email_backend_dev ?? cur.email_backend_dev ?? null,
    cur.created_at ?? now()
  );
  res.json({ ok: true });
});

// Run one analyze→report cycle now (manual trigger / test). Delivers via the
// configured channels (Telegram/email) when set.
router.post('/projects/:id/agent/run', ownProject, async (req, res) => {
  try {
    const out = await runCycle(req.params.id, deliver);
    res.json(out);
  } catch (err) {
    console.error('[agent] run failed', err);
    res.status(500).json({ error: 'run_failed', detail: err.message });
  }
});

// List past agent reports (newest first).
router.get('/projects/:id/reports', ownProject, (req, res) => {
  res.json(db.prepare(
    'SELECT id, created_at, period_start, period_end, report_text, category, delivered FROM agent_reports WHERE project_id = ? ORDER BY created_at DESC LIMIT 100'
  ).all(req.params.id));
});

// One session's full journey (the ordered step list).
router.get('/projects/:id/sessions/:sid', ownProject, (req, res) => {
  const row = db.prepare(
    'SELECT * FROM app_sessions WHERE project_id = ? AND session_id = ?'
  ).get(req.params.id, req.params.sid);
  if (!row) return res.status(404).json({ error: 'not_found' });
  // ETag = the row's updated_at. The journey blob can be 200KB+ for big
  // sessions; serving 304 makes the IDE overlay open instantly on revisit.
  const etag = `"sess-${row.id}-${row.updated_at}"`;
  if (req.headers['if-none-match'] === etag) {
    res.set('ETag', etag);
    res.set('Cache-Control', 'private, max-age=30');
    return res.status(304).end();
  }
  res.set('ETag', etag);
  res.set('Cache-Control', 'private, max-age=30');
  // Surface device metadata captured at ingest time (app_name, app_bundle/
  // app_package, locale, network_type, …) so the session IDE header can show
  // the user-facing app title — not just the bundle id. Pick the FIRST
  // event in the session that carries a non-empty `device` blob (every event
  // ships the same JSON; first-write-wins is fine and cheaper than scanning).
  let device = null;
  try {
    const ev = db.prepare(`
      SELECT device FROM events
      WHERE project_id = ? AND session_id = ? AND device IS NOT NULL AND device <> ''
      ORDER BY timestamp ASC LIMIT 1
    `).get(req.params.id, req.params.sid);
    if (ev && ev.device) device = JSON.parse(ev.device);
  } catch (_) { /* malformed device JSON — leave null */ }
  res.json({
    ...row,
    journey: JSON.parse(row.journey || '[]'),
    device,
  });
});

// Screen wireframe payloads for a session — one entry per screen the SDK
// snapshotted. The SDK posts `screen_layout` events with either:
//   - tree_b64gz (iOS/Android/Flutter) — gzipped JSON, base64-encoded
//   - tree_json  (React Native)         — raw JSON string
// We decode here so the SPA receives a homogeneous { screen, tree } shape.
router.get('/projects/:id/sessions/:sid/layouts', ownProject, (req, res) => {
  const rows = db.prepare(`
    SELECT timestamp, screen, screen_name, properties
    FROM events
    WHERE project_id = ? AND session_id = ? AND event_name = 'screen_layout'
    ORDER BY timestamp ASC
  `).all(req.params.id, req.params.sid);
  const out = [];
  for (const r of rows) {
    let props = {};
    try { props = JSON.parse(r.properties || '{}'); } catch (_) {}
    let tree = null;
    if (typeof props.tree_json === 'string') {
      try { tree = JSON.parse(props.tree_json); } catch (_) {}
    } else if (typeof props.tree_b64gz === 'string') {
      try {
        const gz = Buffer.from(props.tree_b64gz, 'base64');
        // zlib.gunzipSync handles both gzip (with magic 1f 8b) AND raw zlib
        // (Compression.zlib on iOS emits raw deflate w/ zlib header). Try
        // gunzip first; fall back to inflate if it complains.
        let raw;
        try { raw = zlib.gunzipSync(gz); }
        catch (_) { raw = zlib.inflateSync(gz); }
        tree = JSON.parse(raw.toString('utf8'));
      } catch (_) { /* corrupt payload — leave tree null */ }
    }
    if (!tree) continue;
    out.push({
      ts:         r.timestamp,
      screen:     r.screen_name || r.screen || '(unknown)',
      framework:  props.framework || null,
      node_count: props.node_count || 0,
      truncated:  props.truncated === true,
      tree,
    });
  }
  res.json({ layouts: out });
});

// Detail of one journey event across providers: the same event is stored once
// per provider (unitrack / snowplow / firebase) when forwarding is on. Match by
// session + event_name nearest the given timestamp, and return each provider's
// stored payload so the UI can show "what was sent to Snowplow / Firebase".
router.get('/projects/:id/event-detail', ownProject, (req, res) => {
  const { session, name, ts } = req.query;
  if (!name) return res.status(400).json({ error: 'name_required' });
  const t = Number(ts) || 0;
  // The unitrack event always has a session_id (native injects it); provider
  // mirrors (firebase / snowplow forwards) may not — their HTTP post only
  // carries the properties bag, and session_id isn't always in there. So we
  // search in two passes and merge: strict session match for unitrack, and a
  // looser match-by-name-and-time for any provider mirror within ±5s. This
  // catches a Firebase mirror posted 50–200ms after the unitrack twin without
  // pulling in some unrelated event with the same name from another session.
  const NEAR_MS = 5_000;
  const strict = db.prepare(`
    SELECT provider, properties, timestamp, screen_name, element_key
    FROM events
    WHERE project_id = ? AND event_name = ?
      ${session ? 'AND session_id = ?' : ''}
    ORDER BY ABS(timestamp - ?) ASC
    LIMIT 12
  `).all(...(session ? [req.params.id, name, session, t] : [req.params.id, name, t]));

  const byProvider = {};
  for (const r of strict) {
    const p = r.provider || 'unitrack';
    if (!byProvider[p]) {
      let props = {}; try { props = JSON.parse(r.properties || '{}'); } catch (_) {}
      byProvider[p] = { properties: props, timestamp: r.timestamp,
                        screen_name: r.screen_name, element_key: r.element_key };
    }
  }
  // Fill in any missing provider mirror by relaxing the session filter — but
  // only within the ±NEAR_MS window so we don't fetch a same-named event from
  // a different session entirely.
  if (session && t > 0) {
    const loose = db.prepare(`
      SELECT provider, properties, timestamp, screen_name, element_key
      FROM events
      WHERE project_id = ? AND event_name = ? AND provider <> 'unitrack'
        AND timestamp BETWEEN ? AND ?
      ORDER BY ABS(timestamp - ?) ASC
      LIMIT 12
    `).all(req.params.id, name, t - NEAR_MS, t + NEAR_MS, t);
    for (const r of loose) {
      const p = r.provider || 'unitrack';
      if (byProvider[p]) continue;
      let props = {}; try { props = JSON.parse(r.properties || '{}'); } catch (_) {}
      byProvider[p] = { properties: props, timestamp: r.timestamp,
                        screen_name: r.screen_name, element_key: r.element_key };
    }
  }
  res.json({ event_name: name, providers: byProvider });
});

// ----------------------------------------------------------- excel export
router.get('/projects/:id/export', ownProject, async (req, res) => {
  const pid = req.params.id;
  const project = db.prepare('SELECT * FROM projects WHERE id = ?').get(pid);
  if (!project) return res.status(404).json({ error: 'not_found' });
  const events = db.prepare('SELECT * FROM events WHERE project_id = ? ORDER BY id DESC LIMIT 50000').all(pid);
  const defs = db.prepare('SELECT * FROM event_defs WHERE project_id = ?').all(pid);
  const mappings = db.prepare(`
    SELECT m.element_key, d.name def_name FROM event_mappings m
    JOIN event_defs d ON d.id = m.event_def_id WHERE m.project_id = ?
  `).all(pid);

  const buf = await buildWorkbook({ project, events, defs, mappings });
  const safe = (project.name || 'project').replace(/[^a-z0-9_-]+/gi, '_');
  res.setHeader('Content-Type',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  res.setHeader('Content-Disposition', `attachment; filename="${safe}.xlsx"`);
  res.send(buf);
});

// Distinct event names observed for a project — used by the config tab to
// auto-seed the Snowplow schemas map (one iglu URI per known event).
router.get('/projects/:id/event-names', ownProject, (req, res) => {
  const pid = req.params.id;
  const rows = db.prepare(
    'SELECT DISTINCT event_name FROM events WHERE project_id = ? AND event_name IS NOT NULL ORDER BY event_name'
  ).all(pid);
  res.json({ names: rows.map((r) => r.event_name) });
});

// ---------------------------------------------------------- health (1 project)
router.get('/projects/:id/health', ownProject, (req, res) => {
  res.json(projectHealth(req.params.id));
});

// Naming warnings: declared conventions + actually-logged event names that
// don't follow the convention.
router.get('/projects/:id/naming', ownProject, (req, res) => {
  const pid = req.params.id;
  const defNames = db.prepare('SELECT name FROM event_defs WHERE project_id=?').all(pid).map((r) => r.name);
  const logged = db.prepare('SELECT DISTINCT event_name FROM events WHERE project_id=?').all(pid).map((r) => r.event_name);
  const seen = new Set();
  const out = [];
  for (const name of [...defNames, ...logged]) {
    if (seen.has(name)) continue;
    seen.add(name);
    const issues = namingIssues(name);
    out.push({
      name,
      declared: defNames.includes(name),
      logged: logged.includes(name),
      ok: issues.length === 0,
      issues,
    });
  }
  out.sort((a, b) => (a.ok === b.ok ? 0 : a.ok ? 1 : -1)); // problems first
  res.json({
    total: out.length,
    warnings: out.filter((x) => !x.ok).length,
    items: out,
  });
});

// ----------------------------------------------------- CMS: all projects
router.get('/cms/overview', requireAdmin, (_req, res) => {
  const projects = db.prepare('SELECT * FROM projects ORDER BY created_at DESC').all();
  const rows = projects.map((p) => {
    const g = (sql) => db.prepare(sql).get(p.id).n;
    const total = g('SELECT COUNT(*) n FROM events WHERE project_id=?');
    const elementsTotal = db.prepare("SELECT COUNT(DISTINCT element_key) n FROM events WHERE project_id=? AND element_key IS NOT NULL AND element_key<>''").get(p.id).n;
    const elementsDefined = db.prepare('SELECT COUNT(DISTINCT element_key) n FROM event_mappings WHERE project_id=?').get(p.id).n;
    const names = db.prepare('SELECT DISTINCT event_name FROM events WHERE project_id=?').all(p.id).map((r) => r.event_name)
      .concat(db.prepare('SELECT name FROM event_defs WHERE project_id=?').all(p.id).map((r) => r.name));
    const uniqueNames = [...new Set(names)];
    const namingWarnings = uniqueNames.filter((n) => !isValidName(n)).length;
    const health = projectHealth(p.id);
    return {
      id: p.id, name: p.name, app_bundle: p.app_bundle, source_type: p.source_type,
      created_at: p.created_at,
      total_events: total,
      elements_total: elementsTotal,
      elements_defined: elementsDefined,
      definition_rate: elementsTotal ? Math.round((elementsDefined / elementsTotal) * 100) : 0,
      naming_warnings: namingWarnings,
      health,
    };
  });
  const totals = {
    projects: rows.length,
    events: rows.reduce((s, r) => s + r.total_events, 0),
    needs_attention: rows.filter((r) => r.health.grade === 'C' || r.health.grade === 'D').length,
    naming_warnings: rows.reduce((s, r) => s + r.naming_warnings, 0),
  };
  res.json({ totals, projects: rows });
});

module.exports = router;

// Remote config store + resolver.
//
// The portal is the source of truth for an app's tracking setup. The app fetches
// GET {BASE}/config (authenticated by its project api_key) at startup and
// configures UniTrack + providers from the returned JSON — so endpoints, appId,
// schemas, provider settings, super-properties and the event registry can change
// without rebuilding the app.

const { db } = require('./db');

const getRow   = db.prepare('SELECT * FROM project_config WHERE project_id = ?');
const projById = db.prepare('SELECT * FROM projects WHERE id = ?');
const projByKey = db.prepare('SELECT * FROM projects WHERE api_key = ?');

const parse = (s, fallback) => {
  if (s == null || s === '') return fallback;
  try { return JSON.parse(s); } catch (_) { return fallback; }
};

// Sensible defaults so an app with no saved config still tracks to this portal.
function defaults(project) {
  return {
    endpoint: 'https://mobix.asia/event-tracking-mobile/v1/events',
    sdk_config: {
      batchSize: 10, flushIntervalMs: 3000, samplingRate: 1.0,
      autoCapture: true, trackScreens: true, trackTaps: true,
      trackNetwork: true, logLevel: 'warn',
    },
    snowplow: { enabled: false },
    firebase: { enabled: false },
    event_registry: [],
    rules: [],
  };
}

// Full config object for a project id (defaults merged with saved sections).
function configForProject(project) {
  const row = getRow.get(project.id) || {};
  const def = defaults(project);
  return {
    version:        row.version || 1,
    endpoint:       row.endpoint || def.endpoint,
    sdk_config:     parse(row.sdk_config, def.sdk_config),
    snowplow:       parse(row.snowplow, def.snowplow),
    firebase:       parse(row.firebase, def.firebase),
    event_registry: parse(row.event_registry, def.event_registry),
    rules:          parse(row.rules, def.rules),
    updated_at:     row.updated_at || 0,
  };
}

// Save (upsert) any subset of config sections; bumps version.
function saveConfig(projectId, body) {
  const cur = getRow.get(projectId);
  const next = {
    endpoint:       body.endpoint       !== undefined ? body.endpoint : (cur && cur.endpoint),
    sdk_config:     body.sdk_config     !== undefined ? JSON.stringify(body.sdk_config)     : (cur && cur.sdk_config),
    snowplow:       body.snowplow       !== undefined ? JSON.stringify(body.snowplow)       : (cur && cur.snowplow),
    firebase:       body.firebase       !== undefined ? JSON.stringify(body.firebase)       : (cur && cur.firebase),
    event_registry: body.event_registry !== undefined ? JSON.stringify(body.event_registry) : (cur && cur.event_registry),
    rules:          body.rules           !== undefined ? JSON.stringify(body.rules)           : (cur && cur.rules),
  };
  const version = (cur ? cur.version : 0) + 1;
  db.prepare(`
    INSERT INTO project_config (project_id, endpoint, sdk_config, snowplow, firebase, event_registry, rules, version, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(project_id) DO UPDATE SET
      endpoint = excluded.endpoint, sdk_config = excluded.sdk_config,
      snowplow = excluded.snowplow, firebase = excluded.firebase,
      event_registry = excluded.event_registry, rules = excluded.rules,
      version = excluded.version, updated_at = excluded.updated_at
  `).run(projectId, next.endpoint ?? null, next.sdk_config ?? null, next.snowplow ?? null,
         next.firebase ?? null, next.event_registry ?? null, next.rules ?? null, version, Date.now());
  return version;
}

// Open app-facing endpoint: GET {BASE}/config  (auth = project api_key).
// Returns the resolved config the SDK consumes, with a version-based ETag.
function handleConfig(req, res) {
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/);
  const key = m ? m[1] : (req.query.api_key || null);
  const project = key ? projByKey.get(key) : null;
  if (!project) return res.status(401).json({ error: 'unknown_api_key' });

  const cfg = configForProject(project);
  const etag = `"cfg-${project.id}-v${cfg.version}"`;
  if (req.headers['if-none-match'] === etag) return res.status(304).end();
  res.set('ETag', etag);
  res.set('Cache-Control', 'no-cache');
  res.json(cfg);
}

module.exports = { configForProject, saveConfig, handleConfig, projById };

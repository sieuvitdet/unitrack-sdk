// Ingest pipeline: validate → resolve project by API key → normalize → store.

const { db } = require('./db');

const findProjectByKey = db.prepare('SELECT id FROM projects WHERE api_key = ?');

const insertStmt = db.prepare(`
  INSERT OR IGNORE INTO events
    (project_id, event_id, event_name, timestamp, session_id, user_id,
     screen, screen_name, class_name, element_key, platform, app_version,
     properties, device, received_at, source_ip, provider)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

function isValid(e) {
  if (!e
    || !(typeof e.event_id === 'string' || typeof e.event_id === 'number')
    || typeof e.event_name !== 'string'
    || !(typeof e.timestamp === 'number' || typeof e.timestamp === 'string')) {
    return false;
  }
  // Reject unusable timestamps (NaN / 0 / negative / far-future) so session
  // reconstruction never computes a NaN duration. Allow 60s of clock skew.
  const ts = Number(e.timestamp);
  return Number.isFinite(ts) && ts > 0 && ts <= Date.now() + 60_000;
}

// Map an SDK event payload onto our row shape. Device metadata arrives as a
// top-level `device` object; class/element/screen names may live at top level
// or inside properties depending on the binding.
function normalize(e, projectId, ip, provider) {
  const props = e.properties ?? {};
  const device = e.device ?? props.device ?? null;
  return {
    project_id:  projectId,
    event_id:    String(e.event_id),
    event_name:  String(e.event_name),
    timestamp:   Number(e.timestamp),
    // session_id and user_id may travel top-level (the native SDK injects
    // them) OR nested inside `properties` (when the SDK fans an event out via
    // a provider — Firebase / Snowplow mirrors only have the properties bag).
    // Falling back to props lets provider-mirrored events line up with their
    // unitrack twin under the same session in /event-detail.
    session_id:  e.session_id ?? props.session_id ?? null,
    user_id:     e.user_id ?? props.user_id ?? null,
    screen:      e.screen ?? props.screen ?? null,
    screen_name: e.screen_name ?? props.screen_name ?? props.screen ?? e.screen ?? null,
    class_name:  e.class_name ?? props.class_name ?? props.class ?? null,
    element_key: e.element_key ?? props.element ?? props.element_key ?? null,
    platform:    e.platform ?? device?.platform ?? device?.os ?? props.platform ?? null,
    app_version: e.app_version ?? device?.app_version ?? props.app_version ?? null,
    properties:  JSON.stringify(props),
    device:      device ? JSON.stringify(device) : null,
    received_at: Date.now(),
    source_ip:   ip,
    provider:    provider || 'unitrack',
  };
}

const insertMany = (rows) => {
  db.exec('BEGIN');
  let n = 0;
  try {
    for (const r of rows) {
      const res = insertStmt.run(
        r.project_id, r.event_id, r.event_name, r.timestamp, r.session_id,
        r.user_id, r.screen, r.screen_name, r.class_name, r.element_key,
        r.platform, r.app_version, r.properties, r.device, r.received_at, r.source_ip,
        r.provider
      );
      if (res.changes > 0) n++;
    }
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
  return n;
};

// Reusable store path used by the UniTrack ingest AND the Snowplow/Firebase
// endpoints. `events` is an array of raw event objects; tags each with provider.
function storeEvents(events, projectId, ip, provider) {
  const valid = events.filter(isValid).map((e) => normalize(e, projectId, ip, provider));
  const inserted = insertMany(valid);
  return { received: events.length, inserted, rejected: events.length - valid.length };
}

const resolveProjectByKey = (key) => {
  if (!key) return null;
  const row = findProjectByKey.get(key);
  return row ? row.id : null;
};

// Express handler for POST /v1/events
function handleIngest(req, res) {
  const ip = (req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();

  // Resolve project from the Bearer API key. Unknown/missing key => project_id null
  // (events still stored as "unassigned" so nothing is silently dropped).
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/);
  const key = m ? m[1] : (req.query.api_key || null);
  let projectId = null;
  if (key) {
    const row = findProjectByKey.get(key);
    if (row) projectId = row.id;
  }

  let batch = req.body;
  if (!Array.isArray(batch)) batch = [batch];

  // The SDK may tag a forwarded copy with its provider (firebase/snowplow) so
  // the portal can show where it also went. Default is the native UniTrack feed.
  const provider = (req.query.provider || req.headers['x-unitrack-provider'] || 'unitrack');

  let result;
  try {
    result = storeEvents(batch, projectId, ip, provider);
  } catch (err) {
    console.error('[ingest] insert failed', err);
    return res.status(500).json({ error: 'persist_failed' });
  }

  // For native UniTrack events, relay to Snowplow if a forward mapping exists
  // for the event name (lazy require to avoid a circular import with snowplow.js).
  if (provider === 'unitrack' && projectId) {
    try {
      const { maybeForwardToSnowplow } = require('./snowplow');
      for (const e of batch) maybeForwardToSnowplow(e, projectId);
    } catch (err) {
      console.warn('[ingest] snowplow forward error:', err.message);
    }
  }

  console.log(`[ingest:${provider}] +${result.inserted}/${batch.length} project=${projectId ?? '-'} from ${ip}`);
  res.json({ ...result, project_id: projectId });
}

module.exports = { handleIngest, storeEvents, resolveProjectByKey };

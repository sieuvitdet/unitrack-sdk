// Snowplow collector proxy.
//
// The portal exposes a Snowplow-compatible collector endpoint:
//   POST {BASE}/sp/:apiKey/com.snowplowanalytics.snowplow/tp2
// The device's Snowplow tracker is pointed here (instead of the real
// collector). The portal:
//   1) parses the tp2 payload_data batch,
//   2) stores each event as a portal event tagged provider='snowplow',
//   3) optionally forwards the raw body to the real collector (project's
//      sp_forward_url) so the Snowplow pipeline still works — portal is a proxy.
//
// tp2 body: { "schema": "...payload_data...", "data": [ {e, aid, tna, ...}, ... ] }
// Event types (field "e"): se=structured, ue=self-describing, pv=pageview,
// pp=pagePing, tx/ti=transaction. Contexts in "co" (JSON) or "cx" (base64 JSON).

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const { db } = require('./db');
const { storeEvents } = require('./ingest');

const findProject = db.prepare('SELECT id, sp_forward_url FROM projects WHERE api_key = ?');
const findMap = db.prepare(
  'SELECT mode, schema, forward FROM sp_event_maps WHERE project_id = ? AND event_name = ?'
);
const findProjectForward = db.prepare('SELECT sp_forward_url FROM projects WHERE id = ?');

function b64json(s) {
  try { return JSON.parse(Buffer.from(s, 'base64').toString('utf8')); }
  catch (_) { return null; }
}
function asJson(s) {
  if (s == null) return null;
  if (typeof s === 'object') return s;
  try { return JSON.parse(s); } catch (_) { return null; }
}

// Map one Snowplow tp2 event object to the portal's event shape.
function spEventToPortal(sp) {
  // Resolve the self-describing event (ue_pr is JSON, ue_px is base64 JSON).
  let unstruct = asJson(sp.ue_pr) || b64json(sp.ue_px);
  // unstruct = { schema, data:{ schema, data:{...} } }  → unwrap the inner SDJ.
  let sdSchema = null, sdData = null;
  if (unstruct && unstruct.data) {
    sdSchema = unstruct.data.schema || null;
    sdData   = unstruct.data.data || null;
  }

  // Contexts: "co" JSON or "cx" base64. A list of self-describing JSONs.
  const contexts = asJson(sp.co) || b64json(sp.cx);
  const ctxList = (contexts && Array.isArray(contexts.data)) ? contexts.data : [];

  // Event name: structured → se_action; self-describing → last path segment of
  // the iglu schema (e.g. .../camera_stream_started/jsonschema/1-0-0).
  let eventName;
  const type = sp.e;
  if (type === 'se') {
    eventName = sp.se_ac || 'structured';
  } else if (type === 'ue' && sdSchema) {
    const m = sdSchema.match(/\/([a-zA-Z0-9_]+)\/jsonschema/);
    eventName = m ? m[1] : 'self_describing';
  } else {
    eventName = ({ pv: 'page_view', pp: 'page_ping' })[type] || ('sp_' + (type || 'event'));
  }

  // Merge structured fields + self-describing data into properties.
  const props = {};
  if (type === 'se') {
    if (sp.se_ca) props.category = sp.se_ca;
    if (sp.se_la) props.label    = sp.se_la;
    if (sp.se_pr) props.property = sp.se_pr;
    if (sp.se_va) props.value    = sp.se_va;
  }
  if (sdData && typeof sdData === 'object') Object.assign(props, sdData);
  if (sdSchema) props._schema = sdSchema;
  if (ctxList.length) props._contexts = ctxList;

  // Find a user-context entity to lift user_id / screen if present.
  let screen = null;
  for (const c of ctxList) {
    if (c && c.data) {
      if (c.data.name && /screen/i.test(c.schema || '')) screen = c.data.name;
    }
  }

  return {
    event_id:   sp.eid || undefined,           // tp2 event UUID (dedup key)
    event_name: eventName,
    timestamp:  Number(sp.dtm || sp.ttm || Date.now()),
    session_id: sp.sid || null,                // session id from session context not here; sid rare
    user_id:    sp.uid || null,
    screen:     screen,
    platform:   sp.p || null,                  // 'mob' | 'web' | ...
    app_version: null,
    properties: props,
    // device: left null — Snowplow device context lives in _contexts.
  };
}

// Forward the raw tp2 body to the real collector (fire-and-forget, best effort).
function forwardToCollector(forwardUrl, rawBody, headers) {
  try {
    const u = new URL('/com.snowplowanalytics.snowplow/tp2',
                      forwardUrl.replace(/\/+$/, '') + '/');
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request(u, {
      method: 'POST',
      headers: {
        'Content-Type': headers['content-type'] || 'application/json',
        'Content-Length': Buffer.byteLength(rawBody),
      },
      timeout: 8000,
    }, (resp) => { resp.resume(); }); // drain
    req.on('error', (e) => console.warn('[snowplow] forward failed:', e.message));
    req.on('timeout', () => req.destroy());
    req.write(rawBody);
    req.end();
  } catch (e) {
    console.warn('[snowplow] forward url invalid:', e.message);
  }
}

// Express handler for the tp2 collector endpoint.
function handleSnowplow(req, res) {
  const ip = (req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();
  const apiKey = req.params.apiKey;
  const proj = apiKey ? findProject.get(apiKey) : null;
  const projectId = proj ? proj.id : null;

  const body = req.body || {};
  const events = Array.isArray(body.data) ? body.data : [];

  // Store each Snowplow event tagged provider='snowplow'.
  try {
    const mapped = events.map(spEventToPortal);
    storeEvents(mapped, projectId, ip, 'snowplow');
  } catch (e) {
    console.error('[snowplow] store failed', e);
  }

  // Forward to the real collector if configured (proxy mode).
  if (proj && proj.sp_forward_url) {
    forwardToCollector(proj.sp_forward_url, JSON.stringify(body), req.headers);
  }

  console.log(`[snowplow] +${events.length} project=${projectId ?? '-'} forward=${proj && proj.sp_forward_url ? 'yes' : 'no'}`);
  // Snowplow collectors return 200 with no body (or a 1x1 gif for GET).
  res.status(200).json({ ok: true });
}

// ─── UniTrack → Snowplow forwarding ────────────────────────────────────────
// When a UniTrack event arrives and the project has a forward mapping for that
// event name, the portal builds a Snowplow tp2 payload (self-describing or
// structured per the mapping) and relays it to the project's real collector.
// This lets you onboard a NEW Snowplow event by adding a mapping row — no app
// rebuild. Events already sent to Snowplow by the app (no mapping) are skipped.
//
// `evt` is the raw UniTrack event object (event_name, properties, …).
function maybeForwardToSnowplow(evt, projectId) {
  if (!projectId || !evt || !evt.event_name) return;
  const map = findMap.get(projectId, evt.event_name);
  if (!map || !map.forward) return;                 // no mapping / forward off
  const proj = findProjectForward.get(projectId);
  if (!proj || !proj.sp_forward_url) return;        // no collector configured

  const props = evt.properties || {};
  const nowMs = String(Date.now());
  const eid = crypto.randomUUID();

  let spEvent;
  if (map.mode === 'structured') {
    spEvent = {
      e: 'se', eid, dtm: nowMs, p: 'srv',
      se_ca: 'unitrack',
      se_ac: evt.event_name,
      se_la: props.screen || props.screen_name || undefined,
    };
  } else {
    // self-describing: wrap props under the configured iglu schema.
    const ue = {
      schema: 'iglu:com.snowplowanalytics.snowplow/unstruct_event/jsonschema/1-0-0',
      data: { schema: map.schema, data: props },
    };
    spEvent = { e: 'ue', eid, dtm: nowMs, p: 'srv', ue_pr: JSON.stringify(ue) };
  }
  if (evt.user_id) spEvent.uid = evt.user_id;

  const tp2Body = JSON.stringify({
    schema: 'iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4',
    data: [spEvent],
  });
  forwardToCollector(proj.sp_forward_url, tp2Body, { 'content-type': 'application/json' });
}

module.exports = { handleSnowplow, maybeForwardToSnowplow };

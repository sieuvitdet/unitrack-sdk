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

// Fallback path: an event without a sp_event_maps row may still be forwardable
// if (a) the project has a drag-drop mapping for the event's element_key, AND
// (b) the target event_def has sp_schema + sp_forward set. This is the
// "configure Snowplow on the portal without rebuilding the app" path — a tap
// event with element_key="show_testautomations" can be renamed to
// "ev_click_show_testautomations" + forwarded against schema iglu:.../ev_click
// purely by adding a row in event_defs/event_mappings on the portal.
const findDefByElementKey = db.prepare(`
  SELECT d.name, d.sp_schema AS schema, d.sp_forward AS forward, d.sp_entities
    FROM event_mappings m
    JOIN event_defs d ON d.id = m.event_def_id
   WHERE m.project_id = ? AND m.element_key = ?
`);
// Same idea matched on event_name (so an app that has already started calling
// UniTrack.track("ev_click_show_testautomations", ...) keeps forwarding without
// requiring a parallel sp_event_maps row — the event_def IS the config).
const findDefByName = db.prepare(`
  SELECT name, sp_schema AS schema, sp_forward AS forward, sp_entities
    FROM event_defs
   WHERE project_id = ? AND name = ?
`);

// Builders for the iglu entities we know how to fill from the event itself.
// Add a new builder here when the Snowplow team rolls out a new entity schema;
// the portal then exposes the name in the SPA multi-select (no app rebuild).
const ENTITY_BUILDERS = {
  // The user_context schema FPT-Life ships today. Field names match its iglu
  // jsonschema; missing fields are dropped (Snowplow Enrich tolerates that).
  user_context: (evt, device) => ({
    schema: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
    data: dropEmpty({
      username:     evt.user_id,
      epcode:       evt.properties?.epcode,
      platform:     device?.platform || evt.platform,
      device_name:  device?.model,
      device_model: device?.model_family || device?.model,
      device_imei:  device?.install_id,
      app_version:  device?.app_version || evt.app_version,
    }),
  }),
  // core_action carries the wall-clock at which the action started. Snowplow's
  // own `dtm` is collector-side; this is what the app saw.
  core_action: (evt) => ({
    schema: 'iglu:vn.fpt.ftel.snowplow/core_action/jsonschema/1-0-0',
    data: { start_time: fmtTs(evt.timestamp) },
  }),
};

function dropEmpty(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) {
    if (v !== undefined && v !== null && v !== '') out[k] = v;
  }
  return out;
}
function fmtTs(ms) {
  const d = new Date(Number(ms) || Date.now());
  // "YYYY-MM-DD HH:mm:ss" — matches the format FPT-Life ships.
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
         `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
function parseEntityList(json) {
  if (!json) return [];
  try {
    const arr = JSON.parse(json);
    return Array.isArray(arr) ? arr.filter((s) => typeof s === 'string') : [];
  } catch (_) { return []; }
}

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
// When a UniTrack event arrives the portal looks up a mapping in three places,
// in order. The first hit wins. All three describe the same thing — "send this
// event to Snowplow as schema X" — but at different abstraction levels:
//
//   1. sp_event_maps  (legacy)  by event_name. Quick mapping for an event the
//                                app already calls UniTrack.track() with.
//   2. event_defs.name          by event_name. The drag-drop "Define event"
//                                row, now extended with sp_schema/sp_forward.
//                                Used when the app calls UniTrack.track() with
//                                the new event name AFTER it's been wired up.
//   3. event_mappings           by element_key. The "I don't want to rebuild
//                                the app" path: a tap event keeps event_name
//                                "tap" but is forwarded under the def.name
//                                + def.sp_schema picked on the portal.
//
// Renaming a tap into "ev_click_show_testautomations" + relaying it under the
// FPT-Life schema therefore needs no app change — only an event_def + mapping.
function resolveSnowplowConfig(evt, projectId) {
  // (1) explicit sp_event_maps by event_name.
  const raw = findMap.get(projectId, evt.event_name);
  if (raw && raw.forward) {
    return {
      forwardName: evt.event_name,
      mode: raw.mode,
      schema: raw.schema,
      entities: [],                                  // legacy path has no entity config
    };
  }
  // (2) event_defs by event_name — app already calls the new name directly.
  const byName = findDefByName.get(projectId, evt.event_name);
  if (byName && byName.forward && byName.schema) {
    return {
      forwardName: byName.name,
      mode: 'self_describing',
      schema: byName.schema,
      entities: parseEntityList(byName.sp_entities),
    };
  }
  // (3) event_mappings by element_key — tap not renamed at the app side.
  const elKey = evt.element_key
    || (evt.properties && (evt.properties.element_key || evt.properties.element));
  if (elKey) {
    const byEl = findDefByElementKey.get(projectId, elKey);
    if (byEl && byEl.forward && byEl.schema) {
      return {
        forwardName: byEl.name,
        mode: 'self_describing',
        schema: byEl.schema,
        entities: parseEntityList(byEl.sp_entities),
      };
    }
  }
  return null;
}

// `evt` is the raw UniTrack event object (event_name, properties, …).
function maybeForwardToSnowplow(evt, projectId) {
  if (!projectId || !evt || !evt.event_name) return;
  const cfg = resolveSnowplowConfig(evt, projectId);
  if (!cfg) return;                                  // no mapping / forward off
  const proj = findProjectForward.get(projectId);
  if (!proj || !proj.sp_forward_url) return;         // no collector configured

  const props = evt.properties || {};
  const device = evt.device || props.device || null;
  const nowMs = String(Date.now());
  const eid = crypto.randomUUID();

  let spEvent;
  if (cfg.mode === 'structured') {
    spEvent = {
      e: 'se', eid, dtm: nowMs, p: 'srv',
      se_ca: 'unitrack',
      se_ac: cfg.forwardName,
      se_la: props.screen || props.screen_name || evt.screen || undefined,
    };
  } else {
    // self-describing: wrap props under the configured iglu schema.
    const ue = {
      schema: 'iglu:com.snowplowanalytics.snowplow/unstruct_event/jsonschema/1-0-0',
      data: { schema: cfg.schema, data: props },
    };
    spEvent = { e: 'ue', eid, dtm: nowMs, p: 'srv', ue_pr: JSON.stringify(ue) };
  }
  if (evt.user_id) spEvent.uid = evt.user_id;

  // Attach configured entity contexts (user_context, core_action, …). Each
  // builder turns the event + device blob into one SelfDescribingJson.
  if (cfg.entities.length) {
    const builders = cfg.entities
      .map((n) => ENTITY_BUILDERS[n])
      .filter(Boolean);
    if (builders.length) {
      const co = {
        schema: 'iglu:com.snowplowanalytics.snowplow/contexts/jsonschema/1-0-1',
        data: builders.map((b) => b(evt, device)),
      };
      spEvent.co = JSON.stringify(co);
    }
  }

  const tp2Body = JSON.stringify({
    schema: 'iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4',
    data: [spEvent],
  });
  console.log(`[snowplow] forward ${evt.event_name}→${cfg.forwardName} (${cfg.schema || cfg.mode}) entities=${cfg.entities.length} → ${proj.sp_forward_url}`);
  forwardToCollector(proj.sp_forward_url, tp2Body, { 'content-type': 'application/json' });
}

module.exports = { handleSnowplow, maybeForwardToSnowplow };

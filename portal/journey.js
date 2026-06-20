// Journey import & lookup.
//
// QA copy tracking_id từ tab Sessions → gửi đội Snowplow → đội query
// atomic.events trả về JSON. QA upload file đó vào /api/journey/import?
// tracking_id=X. Server parse + lưu tạm 24h vào journey_meta + journey_events
// → frontend dựng user-flow.
//
// Format input chấp nhận:
//   • JSON array `[{event1}, {event2}, ...]`
//   • NDJSON     1 event / dòng
//   • Cả 2 đều là Snowplow atomic.events (schema chuẩn Mobile SDK).
//
// Detect format bằng byte đầu tiên non-whitespace (`[` → array, `{` → ndjson).
//
// Field map từ Snowplow atomic.events:
//   ts          ← derived_tstamp || collector_tstamp || dvce_created_tstamp
//   event_name  ← event_name || event (vd "screen_end", "application_error")
//   screen      ← contexts.screen.name || page_title
//   session_id  ← contexts.client_session.sessionId
//   user_id     ← contexts.client_session.userId
//   platform    ← contexts.mobile_context.osType + ' ' + osVersion
//   app_version ← contexts.application.version
//   tracking_id ← contexts.<tracking_context>.tracking_id  (UniTrack SDK 0.3.32+)
//                  fallback: nếu file chưa có tracking_id ở context, dùng
//                  tracking_id từ URL param và assume file thuộc về session đó.
//
// Mọi event đều phải có session_id khớp 1 session (nếu file chứa nhiều
// session sẽ filter theo session_id của event đầu tiên có tracking_id khớp).

const { db } = require('./db');

const TTL_MS = 24 * 60 * 60 * 1000;

const insertEvent = db.prepare(`
  INSERT INTO journey_events
    (tracking_id, ts, event_name, screen, element_key, props_json)
  VALUES (?, ?, ?, ?, ?, ?)
`);
const upsertMeta = db.prepare(`
  INSERT INTO journey_meta
    (tracking_id, project_id, session_id, user_id, platform, app_version,
     event_count, started_at_ms, ended_at_ms, imported_at, expires_at, source, notes)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(tracking_id) DO UPDATE SET
    project_id    = excluded.project_id,
    session_id    = excluded.session_id,
    user_id       = excluded.user_id,
    platform      = excluded.platform,
    app_version   = excluded.app_version,
    event_count   = excluded.event_count,
    started_at_ms = excluded.started_at_ms,
    ended_at_ms   = excluded.ended_at_ms,
    imported_at   = excluded.imported_at,
    expires_at    = excluded.expires_at,
    source        = excluded.source,
    notes         = excluded.notes
`);
const deleteEventsForTid = db.prepare(`DELETE FROM journey_events WHERE tracking_id = ?`);
const deleteMetaForTid   = db.prepare(`DELETE FROM journey_meta   WHERE tracking_id = ?`);

// ── helpers ─────────────────────────────────────────────────────────────────
function parseJSON(s, fallback) {
  if (s == null || s === '') return fallback;
  try { return JSON.parse(s); } catch (_) { return fallback; }
}

// Snowplow atomic.events lưu `contexts` dưới dạng string JSON
//   { schema: "iglu:.../contexts/jsonschema/1-0-1",
//     data: [ { schema: "iglu:.../client_session/...", data: {...} }, ... ] }
function ctxData(e, schemaContains) {
  const cx = typeof e.contexts === 'string' ? parseJSON(e.contexts, {}) : (e.contexts || {});
  const list = (cx && cx.data) || [];
  const found = list.find(x => x.schema && x.schema.includes(schemaContains));
  return (found && found.data) || null;
}

function tsMs(e) {
  // ưu tiên derived_tstamp (đã enrich), fallback collector hoặc dvce
  const t = e.derived_tstamp || e.collector_tstamp || e.dvce_created_tstamp;
  if (!t) return null;
  const v = (typeof t === 'string') ? Date.parse(t.replace(' ', 'T') + 'Z') : Number(t);
  return Number.isFinite(v) ? v : null;
}

function extractTrackingId(e) {
  // UniTrack SDK 0.3.32+ stamp entity "tracking_context" vào event.
  // Fallback: nếu có field unstruct_event hoặc property top-level (rất hiếm).
  const tc = ctxData(e, 'tracking_context');
  if (tc && tc.tracking_id) return tc.tracking_id;
  // Một số export Snowplow có thể flatten ra cột riêng
  if (e.tracking_id) return e.tracking_id;
  return null;
}

function unstruct(e) {
  // unstruct_event = JSON string of { schema, data:{ schema, data:{...real props} } }
  const u = typeof e.unstruct_event === 'string'
    ? parseJSON(e.unstruct_event, {}) : (e.unstruct_event || {});
  const d1 = (u && u.data) || {};
  return (d1 && d1.data) || d1 || {};
}

// Normalize 1 raw Snowplow event → row trong journey_events
function normalize(e) {
  const ts = tsMs(e);
  if (ts == null) return null;
  const ev = e.event_name || e.event || 'unknown';

  const cs = ctxData(e, 'client_session') || {};
  const sc = ctxData(e, 'screen/jsonschema') || {};
  const mob = ctxData(e, 'mobile_context') || {};
  const app = ctxData(e, 'application/jsonschema') || {};
  const ss = ctxData(e, 'screen_summary') || {};

  const props = unstruct(e);
  // Inject metric chính từ screen_summary để FE đỡ phải ngoáy contexts.
  if (ss && Object.keys(ss).length) Object.assign(props, ss);
  // Thông tin device gói gọn vào properties để FE dùng
  if (mob && Object.keys(mob).length) {
    props._device = {
      manufacturer: mob.deviceManufacturer,
      model: mob.deviceModel,
      os: mob.osType,
      os_version: mob.osVersion,
      network: mob.networkType,
    };
  }
  if (app && app.version) props._app_version = app.version;

  return {
    ts,
    event_name: ev,
    screen: sc.name || e.page_title || null,
    element_key: e.se_label || e.se_action || null,
    props_json: JSON.stringify(props),
    // meta-only, không lưu vào event row
    _meta: {
      session_id: cs.sessionId || null,
      user_id: cs.userId || null,
      platform: mob.osType ? `${mob.osType} ${mob.osVersion || ''}`.trim() : null,
      app_version: app.version || null,
      tracking_id: extractTrackingId(e),
    },
  };
}

// Đọc body (Buffer / string / object đã parse bởi express.json upstream)
// → mảng events thô. Detect format JSON-array vs NDJSON.
function parseInputBuffer(buf) {
  // Express.json upstream có thể đã parse Content-Type: application/json
  // thành object → buf đã là Array hoặc Object. Chấp nhận.
  if (Array.isArray(buf)) return buf;
  if (buf && typeof buf === 'object' && !Buffer.isBuffer(buf)) {
    // single object → wrap thành 1 phần tử
    return [buf];
  }

  const text = Buffer.isBuffer(buf) ? buf.toString('utf8') : String(buf || '');
  const trimmed = text.replace(/^﻿/, '').trimStart();
  if (!trimmed) throw new Error('input rỗng');

  if (trimmed[0] === '[') {
    // JSON array
    const arr = JSON.parse(trimmed);
    if (!Array.isArray(arr)) throw new Error('không phải JSON array');
    return arr;
  }
  if (trimmed[0] === '{') {
    // NDJSON: mỗi line 1 object. Vẫn cho phép trailing newline.
    const lines = trimmed.split(/\r?\n/).filter(l => l.trim().length > 0);
    if (lines.length === 1) {
      // 1 dòng JSON object → wrap thành array
      try { return [JSON.parse(lines[0])]; }
      catch (err) { throw new Error(`JSON parse: ${err.message}`); }
    }
    return lines.map((line, i) => {
      try { return JSON.parse(line); }
      catch (err) { throw new Error(`NDJSON line ${i+1} không parse được: ${err.message}`); }
    });
  }
  throw new Error('không phải JSON array hay NDJSON');
}

// Validate + lưu. Trả về { imported, skipped, meta }.
function importJourney(trackingId, rawBuf, projectId) {
  if (!trackingId) throw new Error('thiếu tracking_id');
  const rawEvents = parseInputBuffer(rawBuf);
  if (!rawEvents.length) throw new Error('không có event trong file');

  // Lọc + normalize, đồng thời validate tracking_id.
  // Strategy: chấp nhận event nếu (a) event có tracking_id khớp trong context,
  // hoặc (b) event không có tracking_id NHƯNG session_id khớp với session_id
  // của những event (a) đầu tiên gặp được. Cho phép file cũ (trước SDK 0.3.32)
  // vẫn import được khi QA tự dán đúng session.
  const normalized = [];
  let primarySid = null;
  let badCtxLine = -1;

  for (let i = 0; i < rawEvents.length; i++) {
    const n = normalize(rawEvents[i]);
    if (!n) continue;
    const m = n._meta;
    if (m.tracking_id) {
      if (m.tracking_id !== trackingId) {
        if (badCtxLine < 0) badCtxLine = i;
        continue;
      }
      if (!primarySid && m.session_id) primarySid = m.session_id;
    }
    normalized.push(n);
  }

  // Nếu không có event nào có tracking_id khớp, fallback: dùng session_id của
  // event đầu (giả định cả file là 1 session, QA tin tưởng).
  if (!primarySid && normalized.length) {
    primarySid = normalized[0]._meta.session_id;
  }

  // Lọc lần 2 theo session_id để cắt nhiễu (nếu file gốc gồm nhiều session)
  const filtered = primarySid
    ? normalized.filter(n => !n._meta.session_id || n._meta.session_id === primarySid)
    : normalized;

  if (!filtered.length) {
    const hint = badCtxLine >= 0
      ? `Event #${badCtxLine + 1} có tracking_id không khớp với '${trackingId}'.`
      : 'Không tìm thấy event hợp lệ trong file.';
    throw new Error(hint);
  }

  // Tổng hợp meta từ event có metadata đầy đủ nhất
  const meta = {
    tracking_id: trackingId,
    project_id: projectId || null,
    session_id: primarySid || null,
    user_id: null,
    platform: null,
    app_version: null,
  };
  for (const n of filtered) {
    if (!meta.user_id && n._meta.user_id) meta.user_id = n._meta.user_id;
    if (!meta.platform && n._meta.platform) meta.platform = n._meta.platform;
    if (!meta.app_version && n._meta.app_version) meta.app_version = n._meta.app_version;
  }

  const tsList = filtered.map(n => n.ts).sort((a,b)=>a-b);
  const startedAt = tsList[0];
  const endedAt = tsList[tsList.length-1];
  const now = Date.now();

  // Replace-style import: xóa data cũ của tracking_id này trước khi ghi mới.
  // node:sqlite (experimental) chưa expose db.transaction(), dùng manual BEGIN/
  // COMMIT/ROLLBACK theo pattern còn lại của portal (agent.js, ingest.js).
  db.exec('BEGIN');
  try {
    deleteEventsForTid.run(trackingId);
    deleteMetaForTid.run(trackingId);
    for (const n of filtered) {
      insertEvent.run(
        trackingId, n.ts, n.event_name, n.screen, n.element_key, n.props_json
      );
    }
    upsertMeta.run(
      meta.tracking_id, meta.project_id, meta.session_id, meta.user_id,
      meta.platform, meta.app_version,
      filtered.length, startedAt, endedAt,
      now, now + TTL_MS,
      'snowplow_export', null
    );
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }

  return {
    imported: filtered.length,
    skipped: rawEvents.length - filtered.length,
    meta: { ...meta, event_count: filtered.length, started_at_ms: startedAt, ended_at_ms: endedAt,
            imported_at: now, expires_at: now + TTL_MS },
  };
}

function getJourney(trackingId) {
  const meta = db.prepare(`SELECT * FROM journey_meta WHERE tracking_id = ?`).get(trackingId);
  if (!meta) return null;
  if (meta.expires_at && meta.expires_at < Date.now()) return null; // hết hạn → coi như không có
  const events = db.prepare(
    `SELECT ts, event_name, screen, element_key, props_json
     FROM journey_events WHERE tracking_id = ? ORDER BY ts ASC`
  ).all(trackingId);
  return {
    meta,
    events: events.map(e => ({
      ts: e.ts,
      event_name: e.event_name,
      screen: e.screen,
      element_key: e.element_key,
      props: parseJSON(e.props_json, {}),
    })),
  };
}

function deleteJourney(trackingId) {
  db.exec('BEGIN');
  try {
    deleteEventsForTid.run(trackingId);
    deleteMetaForTid.run(trackingId);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

// Cron: dọn journey hết hạn. Gọi bằng setInterval 1h từ server.js.
function pruneExpired() {
  const cutoff = Date.now();
  const expiredTids = db.prepare(
    `SELECT tracking_id FROM journey_meta WHERE expires_at < ?`
  ).all(cutoff).map(r => r.tracking_id);
  if (!expiredTids.length) return 0;
  db.exec('BEGIN');
  try {
    for (const tid of expiredTids) {
      deleteEventsForTid.run(tid);
      deleteMetaForTid.run(tid);
    }
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
  return expiredTids.length;
}

module.exports = { importJourney, getJourney, deleteJourney, pruneExpired, TTL_MS };

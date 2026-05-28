// Agent module: session journey reconstruction (Phase 1), flow analytics
// (Phase 2), and the LLM analyze→report pipeline (Phase 4/5).
//
// Design: the core C++ SDK does NOT build journey objects on-device. It emits
// raw events (incl. session_start / session_end boundaries from Phase 0) keyed
// by session_id. This module reconstructs each session's journey server-side by
// querying the events stream ordered by timestamp — simpler, loss-tolerant
// (survives app kill), and the only place with cross-user data for flow stats.

const { db } = require('./db');

// ── default agent system prompts ─────────────────────────────────────────────
// Seeded into agent_config when a project is created (the "root agent"). The
// user can edit them per-project in the portal. Two roles, two prompts:
//   1) Analysis agent — reads flow aggregates + sample sessions, finds the most/
//      least used flows, stuck points, crash-prone spots; classifies each issue.
//   2) Report agent — turns the analysis into a short human report and routes it.
const DEFAULT_ANALYSIS_PROMPT = `Bạn là Agent Phân tích Hành trình Người dùng cho ứng dụng mobile.
ĐẦU VÀO (JSON): flows[{flow_signature, session_count, usage_pct, crash_count, crash_rate, terminate_count, stuck_rate, avg_duration_ms, last_screen}], sample_sessions (chuỗi screen/event/element+ts), error_summary (crash, network status>=400, json_parse_error, memory_warning).
NHIỆM VỤ: (1) flow dùng NHIỀU/ÍT nhất theo session_count; (2) đánh giá độ ổn định mỗi flow nhiều (crash_rate, error_rate, stuck_rate=drop giữa chừng); (3) phát hiện STUCK (màn hay kết thúc đột ngột/lặp/đứng lâu trước background_timeout/terminate); (4) phát hiện DỄ CRASH (màn/transition tập trung crash/memory_warning); (5) quy mỗi vấn đề về MỘT loại: app|network|data|parse.
ĐẦU RA JSON nghiêm ngặt: {top_flows, risky_flows, stuck_points, crash_prone, issues:[{title,severity,category,evidence}]}. KHÔNG bịa số liệu; chỉ dùng dữ liệu đầu vào.`;

const DEFAULT_REPORT_PROMPT = `Bạn là Agent Báo cáo. ĐẦU VÀO: output JSON của Agent Phân tích.
NHIỆM VỤ: (1) viết báo cáo NGẮN GỌN tiếng Việt, ưu tiên vấn đề nặng nhất; (2) mỗi issue ghi category để định tuyến: app→dev mobile, network/data/parse→dev backend; (3) xác định overall_category để chọn kênh gửi; (4) format Telegram (Markdown nhẹ, <4000 ký tự).
ĐẦU RA JSON: {channel_hint, overall_category, subject, body_markdown, routed_to:["mobile_dev"|"backend_dev"]}. Không thêm vấn đề ngoài input. Nếu không có vấn đề nghiêm trọng → báo cáo ngắn "hệ thống ổn định" + top flows.`;

// ── helpers ────────────────────────────────────────────────────────────────
const parseJSON = (s, fallback) => {
  if (s == null || s === '') return fallback;
  try { return JSON.parse(s); } catch (_) { return fallback; }
};

// LLMs often wrap JSON answers in a ```json ... ``` markdown code fence. Strip
// it (and any leading prose) so parseJSON can read the object.
function stripCodeFence(s) {
  if (typeof s !== 'string') return s;
  let t = s.trim();
  // ```json\n...\n```  or  ```\n...\n```
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  if (fence) return fence[1].trim();
  return t;
}

// Strip any module/package prefix from a screen/class name so old qualified
// names ("MyApp.HomeVC") group with bare ones ("HomeVC"). Mirrors the portal
// SPA's cleanScreen() in the tree view.
const cleanScreen = (s) => (s ? String(s).split('.').pop() : '');

// Sessions with no event newer than this and no following session_start are
// considered terminated (app killed / OS reclaimed). Matches the SDK's default
// 30-min session timeout — a session idle longer than this never resumes.
const TERMINATE_GAP_MS = 30 * 60 * 1000;

// ── Phase 1: reconstruction ──────────────────────────────────────────────────

// Build the ordered journey + summary for one session's events (asc by ts).
// Returns the app_sessions row shape (minus project_id/session_id, added by caller).
function buildSessionRow(events) {
  let started_at = null, ended_at = null, ended_reason = 'active';
  let user_id = null, platform = null, app_version = null;
  let crashed = 0;
  let sawStart = false, sawEnd = false;   // first-wins for boundary markers (C2)
  const journey = [];
  const screenPath = [];          // distinct consecutive screens → flow_signature

  for (const e of events) {
    user_id     = e.user_id     || user_id;
    platform    = e.platform    || platform;
    app_version = e.app_version || app_version;

    const props = parseJSON(e.properties, {});
    const screen = cleanScreen(e.screen_name || e.screen || (props && props.screen) || '');

    if (e.event_name === 'crash') crashed = 1;

    // session_start / session_end carry boundary metadata in properties. Honor
    // only the FIRST of each — a duplicate (app retry) must not overwrite the
    // real boundary with a later one. Boundary markers do not advance the
    // fallback ended_at (which tracks the last *real* event).
    if (e.event_name === 'session_start') {
      if (!sawStart && props.started_at) { started_at = props.started_at; sawStart = true; }
      continue; // boundary marker, not a journey step
    }
    if (e.event_name === 'session_end') {
      if (!sawEnd) {
        if (props.reason)   ended_reason = props.reason;   // timeout | background_timeout | manual_reset
        if (props.ended_at) ended_at     = props.ended_at;
        sawEnd = true;
      }
      continue;
    }

    // Real event — track first/last timestamp as a fallback for sessions that
    // lack explicit boundary markers (legacy apps without Phase 0 boundaries).
    // Only set from the fallback when the boundary didn't already provide it.
    if (started_at == null) started_at = e.timestamp;
    if (!sawEnd) ended_at = e.timestamp;

    // Real journey step (screen_view, tap, network_request, app_*, ...).
    journey.push({
      screen,
      event_name: e.event_name,
      element_key: e.element_key || (props && props.url) || null,
      ts: e.timestamp,
    });
    // Track distinct consecutive screens for the flow signature.
    if (screen && screenPath[screenPath.length - 1] !== screen) screenPath.push(screen);
  }

  const duration_ms = (started_at != null && ended_at != null) ? (ended_at - started_at) : null;
  // Sessions with no screen at all (only network/lifecycle/crash) get a synthetic
  // signature so Phase 2's GROUP BY flow_signature doesn't lump every unrelated
  // screenless session into one giant empty-string bucket.
  const flow_signature = screenPath.length ? screenPath.join('>') : '(no_screens)';
  return {
    user_id, platform, app_version,
    started_at, ended_at, ended_reason,
    duration_ms,
    event_count: events.length,
    screen_count: new Set(journey.map((s) => s.screen).filter(Boolean)).size,
    crashed,
    journey: JSON.stringify(journey),
    flow_signature,
  };
}

const upsertSession = db.prepare(`
  INSERT INTO app_sessions
    (project_id, session_id, user_id, platform, app_version, started_at, ended_at,
     ended_reason, duration_ms, event_count, screen_count, crashed, journey,
     flow_signature, updated_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(project_id, session_id) DO UPDATE SET
    user_id = excluded.user_id, platform = excluded.platform,
    app_version = excluded.app_version, started_at = excluded.started_at,
    ended_at = excluded.ended_at, ended_reason = excluded.ended_reason,
    duration_ms = excluded.duration_ms, event_count = excluded.event_count,
    screen_count = excluded.screen_count, crashed = excluded.crashed,
    journey = excluded.journey, flow_signature = excluded.flow_signature,
    updated_at = excluded.updated_at
`);

// Reconstruct (or refresh) app_sessions for a project from its raw events.
// Rebuilds every session that has any event — cheap for the volumes here and
// avoids partial-session bugs. Returns the number of sessions written.
function reconstructSessions(projectId) {
  const sessionIds = db.prepare(`
    SELECT DISTINCT session_id FROM events
    WHERE project_id = ? AND session_id IS NOT NULL AND session_id <> ''
  `).all(projectId);

  const byId = db.prepare(`
    SELECT event_name, timestamp, session_id, user_id, screen, screen_name,
           element_key, platform, app_version, properties
    FROM events
    WHERE project_id = ? AND session_id = ?
    ORDER BY timestamp ASC, id ASC
  `);

  const now = Date.now();
  let n = 0;
  const tx = () => {
    for (const { session_id } of sessionIds) {
      const events = byId.all(projectId, session_id);
      if (!events.length) continue;
      const row = buildSessionRow(events);

      // Infer termination: session still "active" but its last event is older
      // than the terminate gap → the app was killed / never resumed.
      if (row.ended_reason === 'active' && row.ended_at != null
          && (now - row.ended_at) > TERMINATE_GAP_MS) {
        row.ended_reason = 'inferred_terminate';
      }

      upsertSession.run(
        projectId, session_id, row.user_id, row.platform, row.app_version,
        row.started_at, row.ended_at, row.ended_reason, row.duration_ms,
        row.event_count, row.screen_count, row.crashed, row.journey,
        row.flow_signature, now
      );
      n++;
    }
  };
  db.exec('BEGIN');
  try { tx(); db.exec('COMMIT'); }
  catch (err) { db.exec('ROLLBACK'); throw err; }
  return n;
}

// ── Phase 2: flow analytics (heuristic, no LLM) ──────────────────────────────

// Aggregate reconstructed sessions into flows (grouped by flow_signature) so we
// can answer "which flow is used most/least, and does the busy flow break?".
// Pure SQL/JS — no LLM. Refreshes the materialized sessions first so the numbers
// reflect the latest events.
//
//   session_count    how many sessions walked this flow (usage)
//   crash_count/rate  sessions on this flow that hit a crash
//   terminate_count   sessions that ended by inferred_terminate (proxy: the user
//                     dropped mid-flow / app was killed without a clean end)
//   stuck_rate        terminate_count / session_count — flows people get stuck in
//   avg_duration_ms   typical time spent on the flow
//   last_screen       most common final screen (where sessions tend to end)
function computeFlows(projectId, { refresh = true } = {}) {
  if (refresh) {
    try { reconstructSessions(projectId); }
    catch (err) { console.error('[flows] reconstruct failed', err); }
  }

  const rows = db.prepare(`
    SELECT
      flow_signature,
      COUNT(*)                                        AS session_count,
      SUM(crashed)                                    AS crash_count,
      SUM(CASE WHEN ended_reason='inferred_terminate' THEN 1 ELSE 0 END) AS terminate_count,
      AVG(NULLIF(duration_ms, 0))                     AS avg_duration_ms,
      AVG(screen_count)                               AS avg_screen_count,
      MAX(started_at)                                 AS last_seen
    FROM app_sessions
    WHERE project_id = ?
    GROUP BY flow_signature
    ORDER BY session_count DESC
  `).all(projectId);

  const total = rows.reduce((n, r) => n + r.session_count, 0) || 1;
  return rows.map((r) => {
    const steps = (r.flow_signature && r.flow_signature !== '(no_screens)')
      ? r.flow_signature.split('>') : [];
    return {
      flow_signature: r.flow_signature,
      steps,
      last_screen: steps.length ? steps[steps.length - 1] : null,
      session_count: r.session_count,
      usage_pct: Math.round((r.session_count / total) * 1000) / 10,
      crash_count: r.crash_count || 0,
      crash_rate: r.session_count ? Math.round((r.crash_count / r.session_count) * 1000) / 10 : 0,
      terminate_count: r.terminate_count || 0,
      stuck_rate: r.session_count ? Math.round((r.terminate_count / r.session_count) * 1000) / 10 : 0,
      avg_duration_ms: r.avg_duration_ms != null ? Math.round(r.avg_duration_ms) : null,
      avg_screen_count: r.avg_screen_count != null ? Math.round(r.avg_screen_count * 10) / 10 : null,
      last_seen: r.last_seen,
    };
  });
}

// ── Wireframe flow graph (nodes = screens, edges = transitions) ──────────────
//
// Reconstructs a screen-flow graph from every session's journey, with per-node
// and per-edge metrics that drive the heatmap on the portal:
//   node.visits        # sessions that reached this screen
//   node.events        # journey steps recorded on this screen
//   node.avg_dwell_ms  avg time spent on the screen before moving on
//   node.exits         # sessions whose journey ENDED on this screen
//   node.crash_count   # sessions that crashed while on this screen
//   node.stuck_score   0..1 heuristic: high exit ratio or crashes → a "red" node
//   edge.count         # times users moved screen A → B
//   edge.avg_ms        avg transition time A → B
// Returns { nodes, edges, entry_screen, totals }. Pure read of app_sessions.
function computeFlowGraph(projectId, { refresh = true } = {}) {
  if (refresh) {
    try { reconstructSessions(projectId); }
    catch (err) { console.error('[flowgraph] reconstruct failed', err); }
  }

  const rows = db.prepare(
    'SELECT journey, crashed, ended_reason FROM app_sessions WHERE project_id = ?'
  ).all(projectId);

  const nodes = new Map();   // screen → metrics accumulator
  const edges = new Map();   // "A B" → { from, to, count, ms_sum }
  const entryCounts = new Map();
  let sessionCount = 0;

  const node = (s) => {
    if (!nodes.has(s)) nodes.set(s, {
      screen: s, visits: 0, events: 0, dwell_sum: 0, dwell_n: 0,
      exits: 0, crash_count: 0,
    });
    return nodes.get(s);
  };

  for (const r of rows) {
    const journey = parseJSON(r.journey, []);
    if (!Array.isArray(journey) || !journey.length) continue;
    sessionCount++;

    // Collapse the journey into a screen timeline (consecutive same-screen steps
    // merged), tracking when each screen segment started so we can measure dwell.
    // Skip steps with no screen (lifecycle events: app_start, identify,
    // session_started, notification_*) — they are not screens and would
    // otherwise create a bogus "(no_screen)" hub/entry node.
    const segs = [];   // [{ screen, start_ts, last_ts, events }]
    for (const step of journey) {
      const s = step.screen;
      if (!s) continue;
      const prev = segs[segs.length - 1];
      if (prev && prev.screen === s) {
        prev.last_ts = step.ts; prev.events++;
      } else {
        segs.push({ screen: s, start_ts: step.ts, last_ts: step.ts, events: 1 });
      }
    }
    if (!segs.length) continue;

    // Entry screen of this session.
    entryCounts.set(segs[0].screen, (entryCounts.get(segs[0].screen) || 0) + 1);

    const seenInSession = new Set();
    for (let i = 0; i < segs.length; i++) {
      const seg = segs[i];
      const n = node(seg.screen);
      n.events += seg.events;
      if (!seenInSession.has(seg.screen)) { n.visits++; seenInSession.add(seg.screen); }

      // Dwell = time from entering this segment to entering the next (or, for the
      // last segment, the time spent within it).
      const next = segs[i + 1];
      const dwell = next ? (next.start_ts - seg.start_ts) : (seg.last_ts - seg.start_ts);
      if (dwell > 0) { n.dwell_sum += dwell; n.dwell_n++; }

      if (next) {
        const key = seg.screen + ' ' + next.screen;
        if (!edges.has(key)) edges.set(key, { from: seg.screen, to: next.screen, count: 0, ms_sum: 0 });
        const e = edges.get(key);
        e.count++;
        if (next.start_ts > seg.start_ts) e.ms_sum += (next.start_ts - seg.start_ts);
      }
    }

    // The session ended on its last screen.
    const lastScreen = segs[segs.length - 1].screen;
    node(lastScreen).exits++;
    if (r.crashed) node(lastScreen).crash_count++;
  }

  // Finalize node metrics + stuck_score.
  const nodeList = [...nodes.values()].map((n) => {
    const avg_dwell_ms = n.dwell_n ? Math.round(n.dwell_sum / n.dwell_n) : 0;
    const exit_ratio = n.visits ? n.exits / n.visits : 0;
    const crash_ratio = n.visits ? n.crash_count / n.visits : 0;
    // Stuck = sessions tend to end here (exit) or crash here. Weight crashes more.
    const stuck_score = Math.min(1, exit_ratio * 0.6 + crash_ratio * 1.0);
    return {
      screen: n.screen, visits: n.visits, events: n.events,
      avg_dwell_ms, exits: n.exits, crash_count: n.crash_count,
      exit_pct: Math.round(exit_ratio * 1000) / 10,
      stuck_score: Math.round(stuck_score * 100) / 100,
    };
  }).sort((a, b) => b.visits - a.visits);

  const edgeList = [...edges.values()].map((e) => ({
    from: e.from, to: e.to, count: e.count,
    avg_ms: e.count ? Math.round(e.ms_sum / e.count) : 0,
  })).sort((a, b) => b.count - a.count);

  const entry_screen = [...entryCounts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || null;

  return {
    nodes: nodeList,
    edges: edgeList,
    entry_screen,
    totals: { sessions: sessionCount, screens: nodeList.length, transitions: edgeList.length },
  };
}

// ── Phase 4: LLM analyze → report pipeline ───────────────────────────────────

const LLM_TIMEOUT_MS = 60_000;

// Default model when agent_config.llm_model is unset. The team's proxy is
// OpenAI-compatible (POST /v1/chat/completions).
const DEFAULT_LLM_MODEL = 'hosted_vllm/Qwen/Qwen3.5-35B-A3B-FP8';

// Call the LLM endpoint (OpenAI-compatible /v1/chat/completions) with a system
// prompt + user payload. Sends {model, messages, temperature, max_tokens,
// extra_body} and reads choices[0].message.content. Returns the reply string,
// or throws on failure/timeout.
async function callLLM(cfg, system, user) {
  if (!cfg.llm_endpoint) throw new Error('no_llm_endpoint');
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), LLM_TIMEOUT_MS);
  try {
    const headers = { 'Content-Type': 'application/json' };
    if (cfg.llm_api_key) headers['Authorization'] = 'Bearer ' + cfg.llm_api_key;
    const r = await fetch(cfg.llm_endpoint, {
      method: 'POST', headers, signal: ctrl.signal,
      body: JSON.stringify({
        model: cfg.llm_model || DEFAULT_LLM_MODEL,
        messages: [
          { role: 'system', content: system },
          { role: 'user',   content: user },
        ],
        temperature: 0.3,        // analysis should be stable, not creative
        max_tokens: 2048,
        // Disable the model's chain-of-thought so we get the JSON answer
        // directly (faster, cheaper, easier to parse in an automated pipeline).
        extra_body: { chat_template_kwargs: { enable_thinking: false } },
      }),
    });
    if (!r.ok) {
      const body = await r.text().catch(() => '');
      throw new Error('llm_http_' + r.status + (body ? ': ' + body.slice(0, 200) : ''));
    }
    const ct = r.headers.get('content-type') || '';
    if (ct.includes('json')) {
      const j = await r.json();
      // OpenAI-compatible: choices[0].message.content. Tolerate {text}/{output}.
      return (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content)
        || j.text || j.output || JSON.stringify(j);
    }
    return await r.text();
  } finally { clearTimeout(timer); }
}

// Gather the analysis input for a project: flow aggregates + a few sample
// session journeys + an error summary. Heuristic, computed in SQL/JS — the LLM
// only interprets; it never sees raw events.
function buildAnalysisInput(projectId) {
  const flows = computeFlows(projectId, { refresh: true });
  const sample_sessions = db.prepare(`
    SELECT session_id, flow_signature, ended_reason, duration_ms, crashed, journey
    FROM app_sessions WHERE project_id = ?
    ORDER BY (crashed) DESC, (ended_reason='inferred_terminate') DESC, started_at DESC
    LIMIT 8
  `).all(projectId).map((s) => ({
    session_id: s.session_id, flow: s.flow_signature, ended_reason: s.ended_reason,
    duration_ms: s.duration_ms, crashed: !!s.crashed,
    steps: parseJSON(s.journey, []).map((j) => `${j.event_name}@${j.screen}`),
  }));
  const error_summary = db.prepare(`
    SELECT event_name, COUNT(*) count FROM events
    WHERE project_id = ? AND event_name IN ('crash','json_parse_error','memory_warning')
    GROUP BY event_name
  `).all(projectId);
  // network errors: status >= 400 captured in properties of network_request
  const netErr = db.prepare(`
    SELECT COUNT(*) n FROM events
    WHERE project_id = ? AND event_name = 'network_request' AND properties LIKE '%"status":4%'
  `).get(projectId);
  if (netErr && netErr.n) error_summary.push({ event_name: 'network_4xx', count: netErr.n });
  return { flows, sample_sessions, error_summary };
}

// Heuristic fallback when no LLM is configured or the call fails — so a cycle
// always produces *some* report rather than nothing.
function heuristicReport(input) {
  const risky = input.flows.filter((f) => f.crash_rate >= 5 || f.stuck_rate >= 20);
  const top = input.flows.slice(0, 3).map((f) => `• ${f.flow_signature} — ${f.session_count} session (${f.usage_pct}%)`).join('\n');
  let category = 'app';
  if (input.error_summary.some((e) => e.event_name === 'network_4xx')) category = 'network';
  if (input.error_summary.some((e) => e.event_name === 'json_parse_error')) category = 'parse';
  const lines = [];
  lines.push('*Báo cáo tracking (heuristic)*');
  lines.push('\nFlow dùng nhiều:\n' + (top || '— chưa có dữ liệu'));
  if (risky.length) {
    lines.push('\n⚠ Flow cần chú ý:');
    for (const f of risky) lines.push(`• ${f.flow_signature}: crash ${f.crash_rate}%, stuck ${f.stuck_rate}%`);
  } else {
    lines.push('\n✓ Không phát hiện flow rủi ro cao.');
  }
  return { report_text: lines.join('\n'), category, analysis: { heuristic: true, risky_flows: risky } };
}

// Run one full analyze→report cycle for a project. Returns the saved report row
// id + delivery result. Always produces a report (LLM or heuristic fallback).
// `deliverFn` is injected by Phase 5 (delivery) — null means "store only".
async function runCycle(projectId, deliverFn) {
  const cfg = db.prepare('SELECT * FROM agent_config WHERE project_id = ?').get(projectId);
  if (!cfg) throw new Error('no_agent_config');

  const period_end = Date.now();
  const input = buildAnalysisInput(projectId);
  const period_start = db.prepare(
    'SELECT MIN(started_at) t FROM app_sessions WHERE project_id = ?'
  ).get(projectId)?.t || period_end;

  let analysis_json = null, report_text = null, category = 'app';
  try {
    if (!cfg.llm_endpoint) throw new Error('no_llm_endpoint');
    // Agent #1: analysis. Strip any ```json fence the model wraps around it.
    const analysisRaw = stripCodeFence(await callLLM(cfg,
      cfg.analysis_prompt || DEFAULT_ANALYSIS_PROMPT, JSON.stringify(input)));
    analysis_json = analysisRaw;
    // Agent #2: report (input = analysis output).
    const reportRaw = stripCodeFence(await callLLM(cfg,
      cfg.report_prompt || DEFAULT_REPORT_PROMPT, analysisRaw));
    // Report agent returns JSON {overall_category, body_markdown, ...}; tolerate plain text.
    const parsed = parseJSON(reportRaw, null);
    if (parsed && (parsed.body_markdown || parsed.overall_category)) {
      report_text = parsed.body_markdown || reportRaw;
      category = parsed.overall_category || 'app';
    } else {
      report_text = reportRaw;
    }
  } catch (err) {
    // Fallback so the cycle still delivers value when the LLM is down/unset.
    console.warn('[agent] LLM cycle fell back to heuristic:', err.message);
    const h = heuristicReport(input);
    report_text = h.report_text; category = h.category;
    analysis_json = JSON.stringify(h.analysis);
  }

  const info = db.prepare(`
    INSERT INTO agent_reports (project_id, created_at, period_start, period_end, analysis_json, report_text, category, delivered, delivery_log)
    VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL)
  `).run(projectId, Date.now(), period_start, period_end, analysis_json, report_text, category);
  const reportId = info.lastInsertRowid;

  db.prepare('UPDATE agent_config SET last_run_at = ? WHERE project_id = ?').run(Date.now(), projectId);

  let delivered = false, delivery_log = null;
  if (deliverFn) {
    try {
      const res = await deliverFn(cfg, { report_text, category });
      delivered = !!(res && res.delivered);
      delivery_log = JSON.stringify(res || {});
      db.prepare('UPDATE agent_reports SET delivered = ?, delivery_log = ? WHERE id = ?')
        .run(delivered ? 1 : 0, delivery_log, reportId);
    } catch (err) {
      delivery_log = JSON.stringify({ error: err.message });
      db.prepare('UPDATE agent_reports SET delivery_log = ? WHERE id = ?').run(delivery_log, reportId);
    }
  }
  return { report_id: reportId, category, delivered };
}

module.exports = {
  reconstructSessions, buildSessionRow, cleanScreen, computeFlows, computeFlowGraph,
  callLLM, buildAnalysisInput, heuristicReport, runCycle,
  DEFAULT_ANALYSIS_PROMPT, DEFAULT_REPORT_PROMPT,
};

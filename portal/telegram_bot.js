// Telegram command bot (long-polling). Lets you message a project's bot to pull
// info on demand — separate from the scheduled push reports.
//
// Commands (replied in the same chat):
//   /report   — run an analyze→report cycle now and send the report
//   /flows    — top flows by usage with crash/stuck rate
//   /sessions — recent session count + a few latest sessions
//   /status   — project + agent config status
//   /start, /help — list commands
//
// A bot token is bound to a project via agent_config (telegram_token +
// telegram_chat_id). We resolve the project from the incoming chat by matching
// the configured token+chat_id, so commands only work from the configured chat.

const { db } = require('./db');
const { sendTelegram } = require('./deliver');
const { computeFlows, runCycle, reconstructSessions } = require('./agent');

const POLL_TIMEOUT_S = 30;       // Telegram long-poll hold time
const fmtPct = (n) => (n == null ? '—' : n + '%');

// Find the project whose agent_config owns this (token, chat). One bot token may
// serve one project; the chat must match the configured telegram_chat_id.
function projectForChat(token, chatId) {
  return db.prepare(
    'SELECT * FROM agent_config WHERE telegram_token = ? AND telegram_chat_id = ?'
  ).get(token, String(chatId));
}

function projectName(pid) {
  const p = db.prepare('SELECT name FROM projects WHERE id = ?').get(pid);
  return p ? p.name : ('#' + pid);
}

async function handleCommand(token, chatId, text) {
  const cfg = projectForChat(token, chatId);
  if (!cfg) {
    await sendTelegram(token, chatId, 'Chat này chưa gắn với dự án nào. Vào portal → tab Agent để cấu hình.');
    return;
  }
  const pid = cfg.project_id;
  const cmd = text.trim().split(/\s+/)[0].toLowerCase().replace(/@.*$/, ''); // strip @botname

  if (cmd === '/start' || cmd === '/help') {
    await sendTelegram(token, chatId,
      `*UniTrack — ${projectName(pid)}*\n\nLệnh:\n` +
      '`/report` — chạy phân tích + gửi báo cáo ngay\n' +
      '`/flows` — top flow theo lượt dùng + crash/stuck\n' +
      '`/sessions` — số session gần đây\n' +
      '`/status` — tình trạng dự án & agent');
    return;
  }

  if (cmd === '/status') {
    const n = db.prepare('SELECT COUNT(*) n FROM events WHERE project_id = ?').get(pid).n;
    const s = db.prepare('SELECT COUNT(*) n FROM app_sessions WHERE project_id = ?').get(pid).n;
    await sendTelegram(token, chatId,
      `*${projectName(pid)}* — trạng thái\n` +
      `Events: ${n}\nSessions: ${s}\n` +
      `Agent: ${cfg.enabled ? 'bật' : 'tắt'} · LLM: ${cfg.llm_endpoint ? 'đã cấu hình' : 'chưa (dùng heuristic)'}\n` +
      `Lịch: ${cfg.schedule_cron}`);
    return;
  }

  if (cmd === '/flows') {
    let flows = [];
    try { flows = computeFlows(pid); } catch (_) {}
    if (!flows.length) { await sendTelegram(token, chatId, 'Chưa có flow nào (cần session đã reconstruct).'); return; }
    const lines = ['*Top flows — ' + projectName(pid) + '*'];
    for (const f of flows.slice(0, 8)) {
      lines.push(`• ${f.flow_signature} — ${f.session_count} (${fmtPct(f.usage_pct)}) · crash ${fmtPct(f.crash_rate)} · stuck ${fmtPct(f.stuck_rate)}`);
    }
    await sendTelegram(token, chatId, lines.join('\n'));
    return;
  }

  if (cmd === '/sessions') {
    try { reconstructSessions(pid); } catch (_) {}
    const rows = db.prepare(
      'SELECT session_id, flow_signature, ended_reason, crashed FROM app_sessions WHERE project_id = ? ORDER BY started_at DESC LIMIT 5'
    ).all(pid);
    const total = db.prepare('SELECT COUNT(*) n FROM app_sessions WHERE project_id = ?').get(pid).n;
    if (!total) { await sendTelegram(token, chatId, 'Chưa có session nào. App cần gửi event có session_id (journeyCapture).'); return; }
    const lines = [`*Sessions — ${projectName(pid)}* (${total} tổng, 5 gần nhất)`];
    for (const r of rows) {
      lines.push(`• ${r.flow_signature || '(no_screens)'} — ${r.ended_reason}${r.crashed ? ' ⚠crash' : ''}`);
    }
    await sendTelegram(token, chatId, lines.join('\n'));
    return;
  }

  if (cmd === '/report') {
    await sendTelegram(token, chatId, '⏳ Đang chạy phân tích...');
    try {
      const { deliver } = require('./deliver');
      await runCycle(pid, deliver);   // deliver sends the report to this chat
    } catch (err) {
      await sendTelegram(token, chatId, '❌ Lỗi chạy báo cáo: ' + err.message);
    }
    return;
  }

  await sendTelegram(token, chatId, 'Lệnh không hiểu. Gõ /help để xem danh sách.');
}

// Long-poll one bot token continuously. offset tracks the last processed
// update_id; `busy` guards against overlapping getUpdates for the same token
// (Telegram returns 409 Conflict if two long-polls run concurrently).
async function pollToken(token, state) {
  if (state.busy) return;
  state.busy = true;
  try {
    const url = `https://api.telegram.org/bot${token}/getUpdates?timeout=${POLL_TIMEOUT_S}` +
      (state.offset ? `&offset=${state.offset}` : '');
    const r = await fetch(url);
    const j = await r.json().catch(() => ({}));
    if (j.ok) {
      for (const u of j.result) {
        state.offset = u.update_id + 1;
        const m = u.message;
        if (m && m.text && m.text.startsWith('/')) {
          await handleCommand(token, m.chat.id, m.text).catch((e) =>
            console.error('[tgbot] command error:', e.message));
        }
      }
    }
  } catch (err) {
    console.warn('[tgbot] poll error:', err.message);
  } finally {
    state.busy = false;
  }
}

// Discover configured bot tokens and poll each. Re-reads tokens each cycle so a
// newly configured bot is picked up without restart. Only one in-flight
// long-poll per token (the busy guard) — the tick just re-arms finished ones.
const pollStates = new Map();   // token → { offset, busy }
function tick() {
  const tokens = db.prepare(
    "SELECT DISTINCT telegram_token FROM agent_config WHERE enabled = 1 AND telegram_token IS NOT NULL AND telegram_token <> ''"
  ).all().map((r) => r.telegram_token);
  for (const token of tokens) {
    if (!pollStates.has(token)) pollStates.set(token, { offset: 0, busy: false });
    pollToken(token, pollStates.get(token));   // no-op if already polling
  }
}

function start() {
  // Tick every 2s: re-arms any token whose long-poll just returned. A poll holds
  // up to POLL_TIMEOUT_S, so this keeps each token continuously polled without
  // overlapping requests.
  setInterval(tick, 2000);
  console.log('[tgbot] telegram command bot started');
}

module.exports = { start, handleCommand };

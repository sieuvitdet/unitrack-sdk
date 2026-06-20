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
const { sendTelegram, answerCallback } = require('./deliver');
const {
  computeFlows, runCycle, reconstructSessions,
  buildProjectSummary, formatTelegramSummary,
  linkSessions, linkFlows, linkSession,
} = require('./agent');

const POLL_TIMEOUT_S = 30;       // Telegram long-poll hold time
const fmtPct = (n) => (n == null ? '—' : n + '%');

// Find EVERY project whose agent_config owns this (token, chat) pair. A bot
// token used to bind to exactly one project; now we let one bot+chat serve
// several projects so a single Telegram chat can pull reports for FPT Life,
// MobiX, etc. without spawning a bot per project. Callers that need a single
// project still use projectsForChat(...)[0] when the list is length 1, or
// route through the inline-keyboard picker when there are multiple.
function projectsForChat(token, chatId) {
  return db.prepare(
    'SELECT * FROM agent_config WHERE telegram_token = ? AND telegram_chat_id = ? ORDER BY project_id'
  ).all(token, String(chatId));
}

function projectName(pid) {
  const p = db.prepare('SELECT name FROM projects WHERE id = ?').get(pid);
  return p ? p.name : ('#' + pid);
}

// Build an inline keyboard listing every project this (token, chat) can serve.
// Each button carries callback_data = "<cmd>:<pid>" so the user picks the
// project AND the command in one tap. Limit to 2 columns so project names stay
// readable on phones.
function buildProjectPicker(cmd, projects) {
  const buttons = projects.map((p) => ({
    text: projectName(p.project_id),
    callback_data: `${cmd}:${p.project_id}`,
  }));
  const rows = [];
  for (let i = 0; i < buttons.length; i += 2) {
    rows.push(buttons.slice(i, i + 2));
  }
  return { inline_keyboard: rows };
}

async function handleCommand(token, chatId, text) {
  const projects = projectsForChat(token, chatId);
  if (!projects.length) {
    await sendTelegram(token, chatId, 'Chat này chưa gắn với dự án nào. Vào portal → tab Agent để cấu hình.');
    return;
  }
  // Parse "/cmd [pid]" — the pid token is optional and lets the user skip the
  // picker by typing the project id directly (vd "/report 8" for FPT Life).
  const parts = text.trim().split(/\s+/);
  const cmd = parts[0].toLowerCase().replace(/@.*$/, ''); // strip @botname
  const explicitPid = parts[1] ? parseInt(parts[1], 10) : null;

  // /start and /help are not project-specific — they list commands.
  if (cmd === '/start' || cmd === '/help') {
    const projectList = projects.map((p) => `  • #${p.project_id} ${projectName(p.project_id)}`).join('\n');
    await sendTelegram(token, chatId,
      `UniTrack — chat này phục vụ ${projects.length} dự án:\n${projectList}\n\nLệnh:\n` +
      '/report — báo cáo 24h (chọn dự án từ menu)\n' +
      '/flows — top flow theo lượt dùng + crash/stuck\n' +
      '/sessions — link mở danh sách session trên portal\n' +
      '/status — tình trạng dự án & agent\n\n' +
      'Mẹo: thêm số id sau lệnh để bỏ qua menu, vd: /report 8');
    return;
  }

  // Resolve the target project for project-scoped commands:
  //   • explicit pid in the message → use that (must belong to this chat)
  //   • exactly one project on this chat → use it implicitly (legacy behaviour)
  //   • otherwise → send the inline picker; the callback handler re-enters
  //     handleCommand with the chosen pid appended.
  let cfg = null;
  if (explicitPid != null) {
    cfg = projects.find((p) => p.project_id === explicitPid);
    if (!cfg) {
      await sendTelegram(token, chatId,
        `Dự án #${explicitPid} không gắn với chat này. Dùng /help để xem danh sách hợp lệ.`);
      return;
    }
  } else if (projects.length === 1) {
    cfg = projects[0];
  } else {
    // Multi-project + no pid → show picker. Only do this for commands that
    // actually need a target; unknown commands fall through to the help line.
    const projectScoped = new Set(['/report', '/flows', '/sessions', '/status']);
    if (projectScoped.has(cmd)) {
      await sendTelegram(token, chatId, `Chọn dự án cho ${cmd}:`, {
        replyMarkup: buildProjectPicker(cmd, projects),
      });
      return;
    }
  }

  if (!cfg) {
    await sendTelegram(token, chatId, 'Lệnh không hiểu. Gõ /help để xem danh sách.');
    return;
  }
  const pid = cfg.project_id;

  if (cmd === '/status') {
    const n = db.prepare('SELECT COUNT(*) n FROM events WHERE project_id = ?').get(pid).n;
    const s = db.prepare('SELECT COUNT(*) n FROM app_sessions WHERE project_id = ?').get(pid).n;
    await sendTelegram(token, chatId,
      `${projectName(pid)} — trạng thái\n` +
      `Events: ${n}\nSessions: ${s}\n` +
      `Agent: ${cfg.enabled ? 'bật' : 'tắt'} · LLM: ${cfg.llm_endpoint ? 'đã cấu hình' : 'chưa (dùng heuristic)'}\n` +
      `Lịch: ${cfg.schedule_cron}\n\n` +
      `Mở portal: ${linkSessions(pid)}`);
    return;
  }

  if (cmd === '/flows') {
    let flows = [];
    try { flows = computeFlows(pid); } catch (_) {}
    if (!flows.length) { await sendTelegram(token, chatId, 'Chưa có flow nào (cần session đã reconstruct).'); return; }
    const lines = ['Top flows — ' + projectName(pid)];
    for (const f of flows.slice(0, 8)) {
      lines.push(`• ${f.flow_signature} — ${f.session_count} (${fmtPct(f.usage_pct)}) · crash ${fmtPct(f.crash_rate)} · stuck ${fmtPct(f.stuck_rate)}`);
    }
    lines.push('');
    lines.push(`Chi tiết: ${linkFlows(pid)}`);
    await sendTelegram(token, chatId, lines.join('\n'));
    return;
  }

  // /sessions — point to the portal instead of dumping a long list. Show a
  // short header (totals) and 5 most-recent session deep-links so the user can
  // tap straight into one. Each session is one URL line so Telegram renders it
  // as a tappable link.
  if (cmd === '/sessions') {
    try { reconstructSessions(pid); } catch (_) {}
    const total = db.prepare('SELECT COUNT(*) n FROM app_sessions WHERE project_id = ?').get(pid).n;
    if (!total) { await sendTelegram(token, chatId, 'Chưa có session nào. App cần gửi event có session_id (journeyCapture).'); return; }
    const rows = db.prepare(
      'SELECT session_id, flow_signature, ended_reason, crashed FROM app_sessions WHERE project_id = ? ORDER BY started_at DESC LIMIT 5'
    ).all(pid);
    const lines = [`Sessions — ${projectName(pid)} (tổng ${total})`, ''];
    lines.push(`Xem tất cả: ${linkSessions(pid)}`);
    lines.push('');
    lines.push('5 session gần nhất:');
    for (const r of rows) {
      const flag = r.crashed ? ' ⚠crash' : '';
      const flow = r.flow_signature === '(no_screens)' ? '(không có màn)' : (r.flow_signature || '—');
      lines.push(`• ${flow} — ${r.ended_reason}${flag}`);
      lines.push(`  ${linkSession(pid, r.session_id)}`);
    }
    await sendTelegram(token, chatId, lines.join('\n'));
    return;
  }

  if (cmd === '/report') {
    await sendTelegram(token, chatId, `⏳ Đang chạy phân tích cho ${projectName(pid)}...`);
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

// Handle a button tap from the project-picker inline keyboard. Routes back
// through handleCommand with the project id appended so the per-command
// logic stays in one place. answerCallback clears Telegram's spinner.
async function handleCallback(token, chatId, data, queryId) {
  await answerCallback(token, queryId);
  if (!data || !data.includes(':')) return;
  const [cmd, pidStr] = data.split(':', 2);
  const pid = parseInt(pidStr, 10);
  if (!cmd || isNaN(pid)) return;
  // Re-enter handleCommand with the resolved pid baked into the message.
  await handleCommand(token, chatId, `${cmd} ${pid}`);
}

// Long-poll one bot token continuously. offset tracks the last processed
// update_id; `busy` guards against overlapping getUpdates for the same token
// (Telegram returns 409 Conflict if two long-polls run concurrently).
async function pollToken(token, state) {
  if (state.busy) return;
  state.busy = true;
  try {
    // allowed_updates explicit so Telegram sends callback_query updates too
    // (without it, the default whitelist excludes them for some bots and the
    // inline-keyboard buttons just go silent).
    const url = `https://api.telegram.org/bot${token}/getUpdates?timeout=${POLL_TIMEOUT_S}` +
      `&allowed_updates=${encodeURIComponent('["message","callback_query"]')}` +
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
        // callback_query — user tapped an inline-keyboard button (the project
        // picker). Route through handleCallback which re-enters handleCommand
        // with the chosen pid encoded into the synthetic message.
        const cb = u.callback_query;
        if (cb && cb.message && cb.message.chat) {
          await handleCallback(token, cb.message.chat.id, cb.data, cb.id).catch((e) =>
            console.error('[tgbot] callback error:', e.message));
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

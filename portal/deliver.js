// Report delivery (Phase 5): send an agent report to the configured channels.
// Telegram first (no dependency — just a fetch to the Bot API). Email is routed
// by issue category (app → mobile dev, network/data/parse → backend dev) and is
// best-effort via an SMTP relay if configured; left as a stub otherwise.
//
// deliver(cfg, report) → { delivered, channels: [{channel, ok, info}] }

const TELEGRAM_TIMEOUT_MS = 15_000;

async function sendTelegram(token, chatId, text) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TELEGRAM_TIMEOUT_MS);
  try {
    const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: ctrl.signal,
      // Telegram caps messages at 4096 chars.
      body: JSON.stringify({ chat_id: chatId, text: text.slice(0, 4000), parse_mode: 'Markdown' }),
    });
    const j = await r.json().catch(() => ({}));
    return { ok: r.ok && j.ok !== false, info: j.description || ('http_' + r.status) };
  } finally { clearTimeout(timer); }
}

// Route by category: app issues → mobile dev, everything else → backend dev.
function emailRecipient(cfg, category) {
  return category === 'app' ? cfg.email_app_dev : cfg.email_backend_dev;
}

// deliver: try every configured channel; report per-channel result.
async function deliver(cfg, report) {
  const channels = [];
  const text = report.report_text || '(báo cáo trống)';

  // Telegram
  if (cfg.telegram_token && cfg.telegram_chat_id) {
    try {
      const r = await sendTelegram(cfg.telegram_token, cfg.telegram_chat_id, text);
      channels.push({ channel: 'telegram', ok: r.ok, info: r.info });
    } catch (err) {
      channels.push({ channel: 'telegram', ok: false, info: err.message });
    }
  }

  // Email (best-effort, routed by category). No SMTP wired yet — record intent
  // so the routing is visible and ready when an SMTP relay is added.
  const to = emailRecipient(cfg, report.category);
  if (to) {
    channels.push({ channel: 'email', ok: false, info: 'smtp_not_configured', to, category: report.category });
  }

  const delivered = channels.some((c) => c.ok);
  return { delivered, channels };
}

module.exports = { deliver, sendTelegram };

// Agent scheduler (Phase 4): a lightweight ticker that runs each project's
// root-agent cycle ~once a day at its configured hour. No node-cron dependency —
// we only need "daily at hour H", which we derive from the cron's hour field
// (e.g. "0 7 * * *" → 07:00). The ticker wakes every 10 minutes, and for each
// enabled agent whose hour matches and which hasn't run today, runs a cycle.

const { db } = require('./db');
const { runCycle } = require('./agent');
const { deliver } = require('./deliver');

const TICK_MS = 10 * 60 * 1000; // 10 min

// Parse the hour out of a 5-field cron ("m h dom mon dow"). Falls back to 7.
function cronHour(cron) {
  const h = String(cron || '0 7 * * *').trim().split(/\s+/)[1];
  const n = parseInt(h, 10);
  return Number.isInteger(n) && n >= 0 && n <= 23 ? n : 7;
}

const startOfDay = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };

async function tick() {
  const now = Date.now();
  const hour = new Date(now).getHours();
  const agents = db.prepare('SELECT * FROM agent_config WHERE enabled = 1').all();
  for (const cfg of agents) {
    if (cronHour(cfg.schedule_cron) !== hour) continue;        // not this agent's hour
    if (cfg.last_run_at && cfg.last_run_at >= startOfDay(now)) continue; // already ran today
    try {
      console.log(`[scheduler] running agent cycle for project ${cfg.project_id}`);
      await runCycle(cfg.project_id, deliver);
    } catch (err) {
      console.error(`[scheduler] cycle failed for project ${cfg.project_id}:`, err.message);
    }
  }
}

function start() {
  // Run a tick shortly after boot, then on the interval.
  setTimeout(() => { tick().catch((e) => console.error('[scheduler] tick error', e)); }, 30_000);
  setInterval(() => { tick().catch((e) => console.error('[scheduler] tick error', e)); }, TICK_MS);
  console.log('[scheduler] agent scheduler started (10-min ticks)');
}

module.exports = { start, tick, cronHour };

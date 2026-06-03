// Tracking-quality scoring.
//
// Two independent checks plus a composite Health Score (0–100) that answers
// "is this app being tracked well AND actually being used?".
//
//   Naming convention  — does an event name follow the agreed convention?
//   Definition rate    — % of tapped elements mapped to a declared event.
//   Health Score       — weighted blend of 5 signals:
//       coverage 30 · naming 20 · diversity 15 · crash 20 · activity 15

// snake_case: lowercase start, [a-z0-9_], 3–40 chars, at most 4 words.
const SNAKE = /^[a-z][a-z0-9_]*$/;

function namingIssues(name) {
  const issues = [];
  if (!SNAKE.test(name)) issues.push('not_snake_case');
  if (name.length < 3) issues.push('too_short');
  if (name.length > 40) issues.push('too_long');
  if (name.split('_').filter(Boolean).length > 4) issues.push('too_many_words');
  if (/[A-Z]/.test(name)) issues.push('has_uppercase');
  if (/\s/.test(name)) issues.push('has_space');
  return issues;
}

function isValidName(name) {
  return namingIssues(name).length === 0;
}

// The event types a healthy mobile app generally produces. Used for diversity.
// `click` is the convention name SDKs ≥0.2.4 emit for UI button events; `tap`
// is the legacy name (≤0.2.3) — both count so the diversity score doesn't
// drop when an app upgrades the SDK.
const CORE_TYPES = ['screen_view', 'click', 'tap', 'network_request', 'app_start',
  'app_foreground', 'app_background', 'crash'];

/**
 * Compute the project's health.
 * Inputs are plain aggregates so this stays pure + unit-testable.
 *
 *  total            total events
 *  sessions         distinct sessions
 *  crashes          crash events
 *  byEvent          [{event_name, count}]
 *  elementsTotal    distinct tapped elements
 *  elementsDefined  elements mapped to a convention
 *  lastReceivedAt   ms epoch of newest event (or null)
 */
function healthScore(m) {
  const total = m.total || 0;
  const sessions = m.sessions || 0;
  const crashes = m.crashes || 0;
  const names = (m.byEvent || []).map((e) => e.event_name);

  // 1) Coverage (30): defined elements / total elements.
  const coverage = m.elementsTotal > 0 ? m.elementsDefined / m.elementsTotal : 0;

  // 2) Naming (20): share of distinct event names that pass convention.
  const validNames = names.filter(isValidName).length;
  const naming = names.length > 0 ? validNames / names.length : 0;

  // 3) Diversity (15): how many core event types are present.
  const present = CORE_TYPES.filter((t) => names.includes(t)).length;
  const diversity = present / CORE_TYPES.length;

  // 4) Crash health (20): inverse crash-per-session. 0 crashes => 1.0;
  //    >=5% of sessions crashing => 0.
  const crashRate = sessions > 0 ? crashes / sessions : (crashes > 0 ? 1 : 0);
  const crashHealth = Math.max(0, 1 - crashRate / 0.05);

  // 5) Activity (15): app is alive — has recent events and real sessions.
  const ageH = m.lastReceivedAt ? (Date.now() - m.lastReceivedAt) / 3600000 : Infinity;
  const fresh = ageH <= 24 ? 1 : ageH <= 168 ? 0.5 : 0;       // 24h / 7d
  const sessionScore = Math.min(1, sessions / 20);             // ~20 sessions = full
  const activity = 0.5 * fresh + 0.5 * sessionScore;

  const parts = {
    coverage:    Math.round(coverage * 100),
    naming:      Math.round(naming * 100),
    diversity:   Math.round(diversity * 100),
    crash:       Math.round(crashHealth * 100),
    activity:    Math.round(activity * 100),
  };

  const score = Math.round(
    coverage * 30 + naming * 20 + diversity * 15 + crashHealth * 20 + activity * 15
  );

  let grade, verdict;
  if (total === 0)        { grade = 'N/A'; verdict = 'Chưa có dữ liệu'; }
  else if (score >= 80)   { grade = 'A';   verdict = 'Tracking tốt, app hoạt động hiệu quả'; }
  else if (score >= 60)   { grade = 'B';   verdict = 'Ổn, còn điểm cần cải thiện'; }
  else if (score >= 40)   { grade = 'C';   verdict = 'Tracking thiếu hoặc app ít hoạt động'; }
  else                    { grade = 'D';   verdict = 'Cần xem lại: log nghèo hoặc app gần như không dùng'; }

  return { score, grade, verdict, parts, crashRate: Number(crashRate.toFixed(4)) };
}

module.exports = { namingIssues, isValidName, healthScore, SNAKE };

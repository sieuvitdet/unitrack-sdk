// Mobix Event Tracking Portal
// ============================
// Multi-tenant analytics portal for the UniTrack SDK.
//
//   POST  {BASE}/v1/events     ingest a batch (Bearer api_key → project)  [open]
//   POST  {BASE}/auth/*        signup / login / logout / me
//   GET   {BASE}/api/*         management API   [requires login; CMS = admin]
//   GET   {BASE}/healthz       liveness
//   GET   {BASE}/              SPA (shows login when not authenticated)
//
// Auth model:
//   • Users self-register, see/manage only THEIR projects.
//   • Admin (seeded from ADMIN_EMAIL/ADMIN_PASS) sees ALL projects via the CMS.
//   • Ingest stays open — apps authenticate with their per-project API key.

const express = require('express');
const path = require('path');
const { DB_PATH } = require('./db');
const { handleIngest } = require('./ingest');
const { handleSnowplow } = require('./snowplow');
const { handleConfig } = require('./config');
const { handleConfigStream } = require('./config_stream');
const apiRouter = require('./api');
const { buildAuthRouter, requireAuth } = require('./auth');
const scheduler = require('./agent_scheduler');
const telegramBot = require('./telegram_bot');

const PORT      = process.env.PORT      || 4010;
const HOST      = process.env.HOST      || '127.0.0.1';
const BASE_PATH = process.env.BASE_PATH || '/event-tracking-mobile';

const app = express();
app.set('trust proxy', true);
// Ingest payload thường <100KB, nhưng giữ giới hạn rộng phòng app gửi batch
// burst lớn (vd offline replay) — vẫn an toàn vì auth check rồi mới parse.
app.use(express.json({ limit: '100mb' }));
app.use(express.urlencoded({ extended: false }));  // for the no-JS login form

// Minimal cookie parser (avoids a cookie-parser dependency).
app.use((req, _res, next) => {
  req.cookies = {};
  const h = req.headers.cookie;
  if (h) for (const part of h.split(';')) {
    const i = part.indexOf('=');
    if (i > -1) req.cookies[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  next();
});

const router = express.Router();

// CORS cho đường ingest — web SDK chạy trong browser nên bị preflight chặn nếu
// thiếu header này. Chỉ mở trên ingest (auth = api_key trong body/header, không
// dùng cookie) — KHÔNG mở cho /api/* vì đó là cookie-auth, credentials:true +
// origin:* sẽ thành lỗ CSRF.
const ingestCors = (req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'content-type,authorization,x-api-key,x-unitrack-provider,traceparent');
  res.set('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
};
router.options('/v1/events', ingestCors);
router.options('/sp/:apiKey/com.snowplowanalytics.snowplow/tp2', ingestCors);

router.post('/v1/events', ingestCors, handleIngest);   // open — uses project API key
// Snowplow collector-compatible endpoint (proxy). Point a Snowplow tracker's
// collector at {BASE}/sp/<api_key>. Open — auth is the per-project api_key.
router.post('/sp/:apiKey/com.snowplowanalytics.snowplow/tp2', ingestCors, handleSnowplow);

// Lite echo endpoint cho @unitrack/web demo — không lưu DB, chỉ log + trả 200.
// Dùng để team verify event SDK web đến server thật. KHÔNG là production
// pipeline — production app nên dùng /v1/events hoặc /sp/<key>/...
{
  const webEvents = [];
  const WEB_EVENTS_CAP = 200;
  router.post('/web-events', (req, res) => {
    const batch = Array.isArray(req.body) ? req.body : [req.body];
    const stamped = batch.map((ev) => ({
      received_at: Date.now(),
      ip: req.headers['x-forwarded-for'] || req.ip,
      ua: req.headers['user-agent'],
      channel: 'http',
      ...ev,
    }));
    webEvents.unshift(...stamped);
    if (webEvents.length > WEB_EVENTS_CAP) webEvents.length = WEB_EVENTS_CAP;
    console.log(`[web-events] ${stamped.length} event received (total ${webEvents.length})`);
    res.json({ ok: true, received: stamped.length });
  });
  // Snowplow tp2 endpoint — SDK web POST `${endpoint}/com.snowplowanalytics.snowplow/tp2`
  // với body {schema, data:[…]}. Portal accept + đưa vào cùng buffer,
  // tag channel="snowplow" để phân biệt ở UI list.
  router.post('/web-events/com.snowplowanalytics.snowplow/tp2', (req, res) => {
    const payload = req.body || {};
    const events = Array.isArray(payload.data) ? payload.data : [];
    const stamped = events.map((ev) => ({
      received_at: Date.now(),
      ip: req.headers['x-forwarded-for'] || req.ip,
      ua: req.headers['user-agent'],
      channel: 'snowplow',
      // Parse ue_pr + co (Snowplow JSON string-encoded)
      aid: ev.aid,
      eid: ev.eid,
      e: ev.e,
      p: ev.p,
      url: ev.url,
      page: ev.page,
      ue_pr: safeParseJson(ev.ue_pr),
      co: safeParseJson(ev.co),
    }));
    webEvents.unshift(...stamped);
    if (webEvents.length > WEB_EVENTS_CAP) webEvents.length = WEB_EVENTS_CAP;
    console.log(`[snowplow-tp2] ${stamped.length} event received (total ${webEvents.length})`);
    // Snowplow collector protocol expect 200 với body rỗng
    res.status(200).end();
  });
  function safeParseJson(s) {
    if (typeof s !== 'string') return s;
    try { return JSON.parse(s); } catch { return s; }
  }
  router.get('/web-events', (_req, res) => {
    res.json({ count: webEvents.length, events: webEvents });
  });
  router.delete('/web-events', (_req, res) => {
    webEvents.length = 0;
    res.json({ ok: true });
  });
}
// Remote config fetch — open, authenticated by the per-project api_key. The app
// calls this at startup to get its tracking config (endpoint, providers, …).
router.get('/config', handleConfig);
// SSE stream for realtime config changes — the SDK opens this connection in
// foreground and the portal pushes a `config_changed` event whenever a PUT
// to /projects/:id/config bumps the version. Auth = same per-project api_key
// the regular /config GET uses.
router.get('/config/stream', handleConfigStream);
router.get('/healthz', (_req, res) => res.type('text').send('ok'));
router.use('/auth', buildAuthRouter(BASE_PATH));  // signup/login/logout/me
router.use('/api', requireAuth, apiRouter);       // login required (admin gated inside)
// SPA is a single HTML file that must never be cached (so JS updates land
// immediately). Open to all — it shows the login screen when not authenticated.
router.use((req, res, next) => {
  if (req.method === 'GET' && (req.path === '/' || req.path.endsWith('.html'))) {
    res.set('Cache-Control', 'no-store, must-revalidate');
  }
  next();
});
router.use(express.static(path.join(__dirname, 'public'), { etag: false, lastModified: false }));

// SPA fallback for the base path on ANY method. A 303 after the login form
// POST should arrive here as a GET, but some clients (old curl/proxies) replay
// it as POST; static middleware only answers GET/HEAD, so without this they'd
// hit a 404. Always hand back the SPA shell here.
router.all(['/', '/index.html'], (_req, res) => {
  res.set('Cache-Control', 'no-store, must-revalidate');
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.use(BASE_PATH, router);
app.get('/', (_req, res) => res.redirect(BASE_PATH + '/'));

app.listen(PORT, HOST, () => {
  console.log(`[portal] listening on http://${HOST}:${PORT}${BASE_PATH}`);
  console.log(`[portal] db ${DB_PATH}`);
  // Start the agent scheduler (daily analyze→report cycles). Opt out with
  // AGENT_SCHEDULER=off (e.g. for tests / one-off runs).
  if (process.env.AGENT_SCHEDULER !== 'off') {
    scheduler.start();
    telegramBot.start();   // command bot (/report, /flows, ...) via long-poll
  }
});

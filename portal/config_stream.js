// SSE (Server-Sent Events) endpoint for realtime portal config updates.
//
// App opens `GET {BASE}/config/stream?api_key=...&flavor=...`, the server
// keeps the response open and pushes one line per event:
//
//   event: config_changed
//   data: {"version":15}
//
// The SDK reacts by fetching `GET {BASE}/config?flavor=...` and applying the
// new version. Heartbeat lines (`: ping` comments) every 25s keep the
// connection alive past idle proxy timeouts (Nginx default 60s).
//
// Broadcast surface: every PUT to /projects/:id/config calls
// publishConfigChanged(projectId, version) which fans out to all open streams
// for that project. One client per (project_id, flavor) is fine; concurrent
// clients on different flavors get the same broadcast (the SDK is the one
// that decides if its flavor changed by re-fetching).

const { db } = require('./db');

const projByKey = db.prepare('SELECT * FROM projects WHERE api_key = ?');

// projectId → Set<{res, flavor}>. We pin the Express response object so the
// broadcaster can write directly without going through middleware again. A
// Set lets us remove a single client on disconnect in O(1).
const clients = new Map();

// SSE handler. Kept lean — auth + headers + close hook + register. Heartbeat
// fires from a single setInterval the module owns (one timer, all clients)
// so we don't accumulate timers per client.
function handleConfigStream(req, res) {
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/);
  const key = m ? m[1] : (req.query.api_key || null);
  const project = key ? projByKey.get(key) : null;
  if (!project) { res.status(401).json({ error: 'unknown_api_key' }); return; }

  // SSE response headers. `X-Accel-Buffering: no` disables Nginx's response
  // buffering so events flush immediately; without it Nginx holds bytes back
  // until the response closes.
  res.set('Content-Type', 'text/event-stream');
  res.set('Cache-Control', 'no-cache, no-store, no-transform');
  res.set('Connection', 'keep-alive');
  res.set('X-Accel-Buffering', 'no');
  res.flushHeaders?.();

  // Initial hello so the client knows the stream is live even before any
  // config change happens. Useful for debugging "did SSE open?" — also
  // serves as the first connectivity ping.
  res.write(`event: hello\ndata: {"project_id":${project.id}}\n\n`);

  const flavor = (req.query.flavor || req.headers['x-unitrack-flavor'] || '').toString();
  const entry = { res, flavor };
  if (!clients.has(project.id)) clients.set(project.id, new Set());
  clients.get(project.id).add(entry);

  // Remove from the set on disconnect so the broadcaster doesn't try to write
  // to a closed socket. close fires on client navigation, app kill, network
  // drop — all the paths that should free this slot.
  req.on('close', () => {
    const set = clients.get(project.id);
    if (set) { set.delete(entry); if (!set.size) clients.delete(project.id); }
  });
}

// Broadcast a `config_changed` event to every client watching this project.
// The version is the one saveConfig just bumped to; clients use it as a hint
// to decide whether their local cache is stale before re-fetching.
function publishConfigChanged(projectId, version) {
  const set = clients.get(projectId);
  if (!set || !set.size) return;
  const payload = `event: config_changed\ndata: ${JSON.stringify({ version })}\n\n`;
  for (const { res } of set) {
    try { res.write(payload); } catch (_) { /* socket dead; close handler will clean */ }
  }
}

// Heartbeat — Nginx and most proxies kill idle connections after 60s. A
// comment line (starting with `:`) is the SSE-spec ping that costs nothing
// for the client to parse. One interval, all clients.
setInterval(() => {
  for (const set of clients.values()) {
    for (const { res } of set) {
      try { res.write(`: ping\n\n`); } catch (_) {}
    }
  }
}, 25_000).unref();

module.exports = { handleConfigStream, publishConfigChanged };

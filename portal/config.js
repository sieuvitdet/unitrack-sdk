// Remote config store + resolver.
//
// The portal is the source of truth for an app's tracking setup. The app fetches
// GET {BASE}/config (authenticated by its project api_key) at startup and
// configures UniTrack + providers from the returned JSON — so endpoints, appId,
// schemas, provider settings, super-properties and the event registry can change
// without rebuilding the app.

const { db } = require('./db');

const getRow   = db.prepare('SELECT * FROM project_config WHERE project_id = ?');
const projById = db.prepare('SELECT * FROM projects WHERE id = ?');
const projByKey = db.prepare('SELECT * FROM projects WHERE api_key = ?');

const parse = (s, fallback) => {
  if (s == null || s === '') return fallback;
  try { return JSON.parse(s); } catch (_) { return fallback; }
};

// Per-flavor overrides live inside any block under the reserved key
// `flavor_overrides` ({ dev: {...}, staging: {...}, beta: {...}, production: {...} }).
// Apps pass ?flavor=staging (or send X-UniTrack-Flavor) so the portal merges
// the matching override on top of the base block before returning. This is
// what lets one project serve dev/staging/beta/prod from one config row
// without 4 separate projects (and 4 api_keys to juggle).
const KNOWN_FLAVORS = ['dev', 'staging', 'beta', 'production'];
const FLAVOR_KEY = 'flavor_overrides';

// Shallow-merge override onto base, dropping the overrides container so the
// SDK never sees flavor_overrides leaked into its resolved settings. Deep
// nested objects (firebase.options, snowplow.userContext) merge by spreading
// their inner keys too — one level deep is enough for the shapes we use.
function mergeFlavor(base, flavor) {
  if (!base || typeof base !== 'object') return base;
  const overrides = base[FLAVOR_KEY];
  // Clone shallow, drop the overrides container — it's a config-time concept.
  const out = { ...base };
  delete out[FLAVOR_KEY];
  if (!flavor || !overrides || typeof overrides !== 'object') return out;
  const ov = overrides[flavor];
  if (!ov || typeof ov !== 'object') return out;
  for (const [k, v] of Object.entries(ov)) {
    // Merge nested objects (e.g. firebase.options) shallowly, replace primitives/arrays.
    if (v && typeof v === 'object' && !Array.isArray(v)
        && out[k] && typeof out[k] === 'object' && !Array.isArray(out[k])) {
      out[k] = { ...out[k], ...v };
    } else {
      out[k] = v;
    }
  }
  return out;
}

// Sanitize a flavor name: only known values are honoured, anything else falls
// back to "no override" so a typo doesn't silently downgrade to dev.
function resolveFlavor(name) {
  if (!name) return null;
  const v = String(name).toLowerCase().trim();
  return KNOWN_FLAVORS.includes(v) ? v : null;
}

// Sensible defaults so an app with no saved config still tracks to this portal.
function defaults(project) {
  return {
    endpoint: 'https://mobix.asia/event-tracking-mobile/v1/events',
    sdk_config: {
      batchSize: 10, flushIntervalMs: 3000, samplingRate: 1.0,
      autoCapture: true, trackScreens: true, trackTaps: true,
      trackNetwork: true, logLevel: 'warn',
      // Session journey tracking: emit session_start/session_end boundaries so
      // the portal can reconstruct each session's flow. sessionTimeoutMs is the
      // inactivity/background window after which a session is considered closed.
      journeyCapture: true, sessionTimeoutMs: 1800000,
      // Screen-lifecycle event taxonomy. Left empty = core SDK does NOT
      // emit screen_start / screen_end events on transitions (only the
      // back-compat screen_view fires via setScreen). Set these per project
      // to "screen_started" / "screen_ended" (or any name) to enable the
      // pair — screen_end carries dwell_ms (time spent on previous screen).
      screen_start_event: '',
      screen_end_event:   '',
      // Override the swizzler's "screen_load_completed" event name (the one
      // fired in viewDidAppear with load_ms = viewDidLoad → first appearance).
      // Empty = keep default. Useful when team rewrites taxonomy to
      // "screen_load_done" or similar without breaking historic queries.
      screen_load_event:  '',
    },
    // snowplow.blueprints / entities / event_blueprint_map drive the per-event
    // SelfDescribing payload + attached contexts (user_context, core_action,
    // attendance, …) without the app having to hard-code schema URIs. See
    // SnowplowProvider.applyBlueprintConfig in the Flutter SDK + the
    // "📐 Blueprints & Entities" expander in the portal Config tab.
    snowplow: {
      enabled: false,
      // Per-platform overrides for endpoint + appId. Both blocks are optional;
      // when present, the SDK on that platform picks {endpoint, appId} from
      // here in preference to the top-level snowplow.endpoint/appId. Lets one
      // project serve different Snowplow collectors per OS (vd MobiX iOS vs
      // Android targeting different appId in the FPT collector).
      ios:     { endpoint: '', appId: '' },
      android: { endpoint: '', appId: '' },
      // Convention layer: the SDK's tracking* helpers (trackingClickEvent,
      // trackingResultEvent, …) build the iglu schema URI by interpolating
      //   iglu:<iglu_vendor>/<event_name>/jsonschema/<default_version>
      // The app side passes only the convention KIND ("click", "result", …);
      // event_names below maps each kind to the actual event name. Both
      // vendor/version and the mapping live here so a third-party app can
      // re-use the same SDK helpers under their own taxonomy (e.g.
      // "fss_event_click") without forking. Left empty → helpers no-op + warn.
      iglu_vendor:    'vn.fpt.ftel.snowplow',
      default_version: '1-0-0',
      // Map convention kind → event name. Override per project on the portal
      // when a third party wires UniTrack into their own iglu taxonomy.
      // The SDK falls back to the kind itself prefixed with "event_" if a
      // key is missing — so a partial override is safe.
      event_names: {
        click:       'event_click',
        result:      'event_result',
        screen_view: 'event_screen_view',
        crash:       'event_crash',
        api:         'event_api',
        session:     'event_session',
      },
      // Auto-attached context entities for every tracking* call. Two names
      // are built into the SDK (data sourced from setUser + event meta):
      //   user_context — fields populated from userContext + setUser traits.
      //   core_action  — action_name (event_names value), timestamp, screen,
      //                  element_key.
      // Any other name added here is registered too, but the app must pass
      // its data via the helper's extraContexts: parameter — the SDK only
      // knows how to build the two above without app input.
      entities: {
        user_context: 'iglu:vn.fpt.ftel.snowplow/user_context/jsonschema/1-0-0',
        core_action:  'iglu:vn.fpt.ftel.snowplow/core_action/jsonschema/1-0-0',
      },
    },
    firebase: { enabled: false },
    // W3C distributed tracing. Default OFF + empty allowlist — the SDK is
    // fail-closed on the host side too, so a fresh project never injects
    // `traceparent` until an operator opts in (and types the internal hosts).
    tracing: {
      enabled: false,
      header_name: 'traceparent',
      allowlist_hosts: [],
      sampled: true,
    },
  };
}

// Full config object for a project id (defaults merged with saved sections).
//
// If `flavor` is one of KNOWN_FLAVORS, every block's `flavor_overrides[<flavor>]`
// is merged on top before returning. `flavor=null` returns the raw blocks
// (the portal SPA uses this form so an operator sees + edits the overrides).
function configForProject(project, flavor = null) {
  const row = getRow.get(project.id) || {};
  const def = defaults(project);
  const resolved = resolveFlavor(flavor);
  const blocks = {
    sdk_config: parse(row.sdk_config, def.sdk_config),
    snowplow:   parse(row.snowplow,   def.snowplow),
    firebase:   parse(row.firebase,   def.firebase),
    tracing:    parse(row.tracing,    def.tracing),
  };
  // For the app-facing call (resolved flavor set), strip flavor_overrides from
  // every block + apply the matching override. For the editor call (no flavor),
  // hand back the raw blocks so the UI can render the overrides as fields.
  const out = resolved
    ? {
        sdk_config: mergeFlavor(blocks.sdk_config, resolved),
        snowplow:   mergeFlavor(blocks.snowplow,   resolved),
        firebase:   mergeFlavor(blocks.firebase,   resolved),
        tracing:    mergeFlavor(blocks.tracing,    resolved),
      }
    : blocks;
  return {
    version:        row.version || 1,
    endpoint:       row.endpoint || def.endpoint,
    flavor:         resolved,
    ...out,
    updated_at:     row.updated_at || 0,
  };
}

// Save (upsert) any subset of config sections; bumps version.
function saveConfig(projectId, body) {
  const cur = getRow.get(projectId);
  const next = {
    endpoint:   body.endpoint   !== undefined ? body.endpoint                : (cur && cur.endpoint),
    sdk_config: body.sdk_config !== undefined ? JSON.stringify(body.sdk_config) : (cur && cur.sdk_config),
    snowplow:   body.snowplow   !== undefined ? JSON.stringify(body.snowplow)   : (cur && cur.snowplow),
    firebase:   body.firebase   !== undefined ? JSON.stringify(body.firebase)   : (cur && cur.firebase),
    tracing:    body.tracing    !== undefined ? JSON.stringify(body.tracing)    : (cur && cur.tracing),
  };
  const version = (cur ? cur.version : 0) + 1;
  db.prepare(`
    INSERT INTO project_config (project_id, endpoint, sdk_config, snowplow, firebase, tracing, version, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(project_id) DO UPDATE SET
      endpoint = excluded.endpoint, sdk_config = excluded.sdk_config,
      snowplow = excluded.snowplow, firebase = excluded.firebase,
      tracing = excluded.tracing,
      version = excluded.version, updated_at = excluded.updated_at
  `).run(projectId, next.endpoint ?? null, next.sdk_config ?? null, next.snowplow ?? null,
         next.firebase ?? null,
         next.tracing ?? null, version, Date.now());
  return version;
}

// Open app-facing endpoint: GET {BASE}/config  (auth = project api_key).
// Returns the resolved config the SDK consumes, with a version-based ETag.
//
// Flavor selection (optional): apps pass ?flavor=dev|staging|beta|production
// or the X-UniTrack-Flavor header. The ETag includes the resolved flavor so
// switching builds (debug → release) doesn't reuse a stale cached response.
function handleConfig(req, res) {
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/);
  const key = m ? m[1] : (req.query.api_key || null);
  const project = key ? projByKey.get(key) : null;
  if (!project) return res.status(401).json({ error: 'unknown_api_key' });

  const flavor = resolveFlavor(req.query.flavor || req.headers['x-unitrack-flavor']);
  const cfg = configForProject(project, flavor);
  const etag = `"cfg-${project.id}-v${cfg.version}-${flavor || 'base'}"`;
  if (req.headers['if-none-match'] === etag) return res.status(304).end();
  res.set('ETag', etag);
  res.set('Cache-Control', 'no-cache');
  res.json(cfg);
}

module.exports = {
  configForProject, saveConfig, handleConfig, projById,
  // Exported for the agent / SPA-side helpers that need to know which flavors
  // the portal recognises (keeps the list in one place).
  KNOWN_FLAVORS,
  mergeFlavor,
  resolveFlavor,
};

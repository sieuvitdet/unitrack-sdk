"use strict";
// @unitrack/react-native
//
// Public API. Calls the native module which forwards to the iOS / Android
// SDK installed underneath. Auto-capture (screens, taps, network) is
// configured on the native side; React Navigation hooks add JS-level
// screen tracking on top.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
var _a;
Object.defineProperty(exports, "__esModule", { value: true });
exports.safeJsonParse = exports.createNavigationTracker = exports.tapState = exports.UniTrackTapBoundary = exports.UniTrackRemoteConfig = void 0;
exports.installDeeplinkAutoCapture = installDeeplinkAutoCapture;
exports.installThirdPartyOpenAutoCapture = installThirdPartyOpenAutoCapture;
const react_native_1 = require("react-native");
const tapState_1 = require("./tapState");
const traceContext_1 = require("./traceContext");
// Strip query strings for privacy — log scheme://host/path only.
function hostPath(url) {
    const m = /^([a-z][a-z0-9+.-]*:\/\/[^/?#]+)([^?#]*)/i.exec(url);
    return m ? m[1] + m[2] : url.split('?')[0];
}
const LINK_HINT = `[UniTrack] Native module not found. ` +
    `Ensure '@unitrack/react-native' is properly linked. ` +
    `Run 'pod install' (iOS) and rebuild.`;
const native = (_a = react_native_1.NativeModules.UniTrack) !== null && _a !== void 0 ? _a : new Proxy({}, {
    get() {
        throw new Error(LINK_HINT);
    },
});
var remoteConfig_1 = require("./remoteConfig");
Object.defineProperty(exports, "UniTrackRemoteConfig", { enumerable: true, get: function () { return remoteConfig_1.UniTrackRemoteConfig; } });
class UniTrackClass {
    constructor() {
        this.initialized = false;
        // Set once at module load — used by trackDeeplink to decide `is_cold`.
        // (Module load runs during the React Native bridge boot, so deeplinks that
        // launch the app via Linking.getInitialURL fire within the first few seconds
        // of this timestamp.)
        this.bootAt = Date.now();
        // Registered third-party providers (Snowplow, Firebase, …). Every event is
        // forwarded to each one. Empty by default — core has zero such dependencies.
        this.providers = [];
        // Convention layer — portal `snowplow.event_names` maps a 6-kind taxonomy
        // (click / result / screen_view / crash / api / session) onto the wire
        // event names. setEventNames() is typically called from
        // UniTrackRemoteConfig.applyConventions(cfg) so the SDK is in sync with
        // the portal without an app rebuild.
        this.eventNames = {};
        // Lazy EventEmitter — created on the first onFlushCompleted subscription
        // so apps that never use it pay no setup cost.
        this.flushEmitter = null;
        this.flushSubscribers = 0;
    }
    /** Register a provider to also receive every event. Call BEFORE initialize();
     *  if called afterwards, the provider is initialized immediately. */
    addProvider(provider) {
        this.providers.push(provider);
        if (this.initialized) {
            Promise.resolve(provider.initialize()).catch((e) => console.warn('[UniTrack] provider init failed', e));
        }
    }
    // Run an action against every provider, isolating failures.
    forEachProvider(action) {
        for (const p of this.providers) {
            try {
                action(p);
            }
            catch (e) {
                console.warn('[UniTrack] provider forward failed', e);
            }
        }
    }
    async initialize(apiKey, config = {}) {
        if (this.initialized)
            return;
        await native.initialize(apiKey, JSON.stringify(config));
        this.initialized = true;
        this.installFetchInterceptor();
        // Bring up any providers registered before initialize().
        for (const p of this.providers) {
            try {
                await p.initialize();
            }
            catch (e) {
                console.warn('[UniTrack] provider init failed', e);
            }
        }
    }
    identify(userId, traits = {}) {
        this.forEachProvider((p) => p.setUser(userId, traits));
        return native.identify(userId, JSON.stringify(traits));
    }
    reset() {
        this.forEachProvider((p) => p.setUser(null, {}));
        return native.reset();
    }
    /**
     * Apply W3C distributed-tracing settings. The fetch interceptor reads this
     * snapshot per request; cheap to call repeatedly (e.g. from a remote-config
     * fetch).
     *
     * `allowlistHosts` is fail-closed: empty list ⇒ never inject, so the
     * `traceparent` header doesn't leak to Firebase/Maps/CDNs by default. Each
     * entry is either an exact host (`api.example.com`) or a wildcard suffix
     * (`*.example.com`, which matches every subdomain plus the bare apex).
     */
    setTracing(opts) {
        var _a, _b, _c;
        traceContext_1.tracingState.current = {
            enabled: opts.enabled,
            headerName: (_a = opts.headerName) !== null && _a !== void 0 ? _a : 'traceparent',
            allowlistHosts: (_b = opts.allowlistHosts) !== null && _b !== void 0 ? _b : [],
            sampled: (_c = opts.sampled) !== null && _c !== void 0 ? _c : true,
        };
    }
    /** Mint a fresh (trace_id, span_id) — exposed so app code can correlate
     *  push payloads or deep-links with backend logs by trace_id. */
    newTrace() { return (0, traceContext_1.newTrace)(); }
    setEventNames(map) {
        this.eventNames = { ...map };
    }
    resolveKind(name) {
        const v = this.eventNames[name];
        return (v && v.length > 0) ? v : name;
    }
    // Map a raw auto-capture event ("click", "screen_load_completed", …) to its
    // convention kind. Returns null when the event isn't recognised — those go
    // out under their own name (legacy behaviour). Matches the Flutter Snowplow
    // provider's _kindForRawEvent so cross-platform shapes stay aligned.
    kindForRawEvent(raw) {
        switch (raw) {
            case 'click': return 'click';
            case 'screen_load_completed':
            case 'screen_viewed':
            case 'screen_exited':
            case 'screen_view': return 'screen_view';
            case 'crash':
            case 'application_error': return 'crash';
            case 'network_request': return 'api';
            case 'session_started':
            case 'session_ended': return 'session';
        }
        return null;
    }
    track(event, properties = {}) {
        var _a;
        let name = event;
        let props = properties;
        // If the caller passed a convention kind directly (or an auto-capture
        // event maps to one), resolve to the portal-configured wire name AND
        // stamp the business signal as `event_name` in the payload so a single
        // iglu schema carries both the generic shape and the specific business.
        const kind = this.eventNames[event] ? event : this.kindForRawEvent(event);
        if (kind && this.eventNames[kind]) {
            name = this.eventNames[kind];
            // Caller may already have populated event_name — don't clobber it.
            const business = (_a = properties.event_name) !== null && _a !== void 0 ? _a : event;
            props = { event_name: business, ...properties };
        }
        this.forEachProvider((p) => p.track(name, props));
        return native.track(name, JSON.stringify(props));
    }
    setScreen(name) {
        this.forEachProvider((p) => p.setScreen(name));
        return native.setScreen(name);
    }
    flush() { return native.flush(); }
    setEnabled(e) { return native.setEnabled(e); }
    // ─── Session API parity (iOS / Android / Flutter) ──────────────────────
    //
    // The native core owns session_id rotation + persists session_index across
    // launches via session.json. Apps call these instead of keeping their own
    // (resetting-on-cold-start) counter.
    /** UUID of the active session — empty before init. */
    currentSessionId() { return native.currentSessionId(); }
    /** Lifetime session counter (persists across launches). 1 on first
     *  install, +1 per timeout-driven rotation. */
    sessionIndex() { return native.sessionIndex(); }
    /** UUID of the session that just closed; empty on the first session after
     *  install. Pair with [currentSessionId] when emitting session_started. */
    previousSessionId() { return native.previousSessionId(); }
    /** Force a session rotation now. Bumps sessionIndex, mints a new UUID,
     *  records the just-closed UUID as previousSessionId. Use on logout /
     *  switch-account / new-context boundaries when the inactivity timeout
     *  isn't enough. */
    rotateSession() { return native.rotateSession(); }
    // ─── Offline queue introspection ───────────────────────────────────────
    /** Snapshot of events still sitting in the SQLite offline queue, grouped
     *  by raw event_name. Used by debug toasts during airplane-mode testing:
     *  `Saved 7 ev_screen_view, 3 ev_click`. Empty before init or queue empty. */
    pendingEventCounts() {
        return native.pendingEventCounts();
    }
    /** Fires after each successful batch upload with the per-event_name
     *  breakdown of THAT batch (vd `{ev_click: 3, ev_result: 2}`). Returns
     *  an [EmitterSubscription]; call `.remove()` when you're done so the
     *  native worker stops posting if no other listener remains. */
    onFlushCompleted(handler) {
        if (!this.flushEmitter) {
            this.flushEmitter = new react_native_1.NativeEventEmitter(react_native_1.NativeModules.UniTrack);
        }
        if (this.flushSubscribers === 0) {
            native.setFlushCallbackEnabled(true).catch(() => { });
        }
        this.flushSubscribers += 1;
        const sub = this.flushEmitter.addListener('onFlushCompleted', (e) => {
            var _a;
            handler((_a = e === null || e === void 0 ? void 0 : e.counts) !== null && _a !== void 0 ? _a : {});
        });
        // Wrap .remove() so we can toggle the native flag off when the last
        // subscriber goes away.
        const origRemove = sub.remove.bind(sub);
        sub.remove = () => {
            origRemove();
            this.flushSubscribers = Math.max(0, this.flushSubscribers - 1);
            if (this.flushSubscribers === 0) {
                native.setFlushCallbackEnabled(false).catch(() => { });
            }
        };
        return sub;
    }
    // ─── Application context + remote values ───────────────────────────────
    /** Device/app metadata bag captured at init (platform, app_version,
     *  network_*, device_*). Same dict the native Snowplow provider uses to
     *  build its `application_context` entity. Empty before init. */
    applicationContext() {
        return native.applicationContext();
    }
    /** Resolve a runtime value. Resolution order:
     *    1. Portal `sdk_config.custom_values[key]`
     *    2. Any registered remote-value provider (Firebase RC)
     *    3. [defaultValue]
     *
     *  T may be `string | number | boolean`. Coercion happens on the native
     *  side based on the type of [defaultValue]. */
    async getRemoteValue(key, defaultValue) {
        let hint;
        if (typeof defaultValue === 'boolean')
            hint = 'bool';
        else if (typeof defaultValue === 'number') {
            hint = Number.isInteger(defaultValue) ? 'int' : 'double';
        }
        else
            hint = 'string';
        try {
            const raw = await native.getRemoteValue(key, hint);
            if (raw == null)
                return defaultValue;
            return raw;
        }
        catch {
            return defaultValue;
        }
    }
    // ─── Session-stat sidebag ──────────────────────────────────────────────
    sessionScreenCount() { return native.sessionScreenCount(); }
    sessionHadError() { return native.sessionHadError(); }
    sessionHadCrash() { return native.sessionHadCrash(); }
    incrementScreenCount() { return native.incrementScreenCount(); }
    markSessionError() { return native.markSessionError(); }
    markSessionCrash() { return native.markSessionCrash(); }
    resetSessionStats() { return native.resetSessionStats(); }
    // --- semantic event helpers (Phase 3) ----------------------------------
    /** Notification received/opened/dismissed.
     *  state: 'foreground'|'background'|'silent'
     *  action: 'received'|'opened'|'dismissed' (default 'received')
     *  notificationId: platform id (FCM messageId / APNs id) so the portal can
     *    dedup the same push across deliver/open
     *  data: raw payload (usually carries routing keys like deeplink/campaign_id)
     */
    trackNotification(opts) {
        var _a;
        return this.track('notification', {
            state: opts.state, action: (_a = opts.action) !== null && _a !== void 0 ? _a : 'received',
            ...(opts.title ? { title: opts.title } : {}),
            ...(opts.body ? { body: opts.body } : {}),
            ...(opts.notificationId ? { notification_id: opts.notificationId } : {}),
            ...(opts.data ? { data: opts.data } : {}),
        });
    }
    trackWebViewOpen(url, screen) {
        return this.track('webview_open', { url: hostPath(url), ...(screen ? { screen } : {}) });
    }
    /** A deeplink / universal link opened the app or a screen.
     *  Adds scheme/host/path/query separately + is_cold flag (true when fired
     *  within 5s of module load = the link launched the app). */
    trackDeeplink(url, source) {
        const props = { url };
        try {
            const u = new URL(url);
            if (u.protocol)
                props.scheme = u.protocol.replace(/:$/, '');
            if (u.host)
                props.host = u.host;
            if (u.pathname)
                props.path = u.pathname;
            if (u.search)
                props.query = u.search.replace(/^\?/, '');
        }
        catch (_) { /* malformed — keep just the raw URL */ }
        if (source)
            props.source = source;
        props.is_cold = Date.now() - this.bootAt <= 5000;
        return this.track('deeplink', props);
    }
    trackThirdPartyOpen(name, screen) {
        return this.track('third_party_open', { target: name, ...(screen ? { screen } : {}) });
    }
    /**
     * Install global fetch interceptor for network tracking at the JS layer.
     * Native auto-capture on iOS already covers URLSession, but RN's fetch
     * goes through its own networking stack — this catches JS-side calls.
     */
    installFetchInterceptor() {
        const orig = global.fetch;
        if (!orig || orig.__unitrack_wrapped)
            return;
        const wrapped = async (input, init) => {
            var _a, _b;
            const start = Date.now();
            const url = typeof input === 'string' ? input :
                input instanceof URL ? input.toString() : input.url;
            const method = (_a = init === null || init === void 0 ? void 0 : init.method) !== null && _a !== void 0 ? _a : 'GET';
            let status = 0, respBytes = 0, errMsg = '';
            // W3C tracing: mint a (trace_id, span_id) if enabled AND host is
            // allowlisted AND the caller hasn't already set the header. We mutate a
            // local headers Map (Headers constructor handles all 3 input shapes:
            // plain object, [string,string][], or another Headers).
            const tc = traceContext_1.tracingState.current;
            let traceIds;
            let nextInit = init;
            if (tc.enabled && (0, traceContext_1.shouldInjectTrace)((0, traceContext_1.hostOf)(input), tc.allowlistHosts)) {
                const headers = new Headers(init === null || init === void 0 ? void 0 : init.headers);
                if (!headers.has(tc.headerName)) {
                    traceIds = (0, traceContext_1.newTrace)();
                    headers.set(tc.headerName, (0, traceContext_1.traceparentHeader)(traceIds, tc.sampled));
                    nextInit = { ...(init !== null && init !== void 0 ? init : {}), headers };
                }
            }
            try {
                const res = await orig(input, nextInit);
                status = res.status;
                const cl = res.headers.get('content-length');
                if (cl)
                    respBytes = parseInt(cl, 10) || 0;
                return res;
            }
            catch (e) {
                errMsg = String((_b = e === null || e === void 0 ? void 0 : e.message) !== null && _b !== void 0 ? _b : e);
                throw e;
            }
            finally {
                const dur = Date.now() - start;
                const reqBody = init === null || init === void 0 ? void 0 : init.body;
                const reqBytes = typeof reqBody === 'string' ? reqBody.length : 0;
                // Mirror the button/screen that triggered this call (set by the tap
                // boundary), so an API error can be traced back to its button + screen.
                const tap = tapState_1.tapState.last;
                const mirrored = tap && Date.now() - tap.at < 10000;
                this.track('network_request', {
                    url: url.split('?')[0],
                    method,
                    status,
                    duration_ms: dur,
                    req_bytes: reqBytes,
                    resp_bytes: respBytes,
                    error: errMsg,
                    // Carry trace ids on the event so the portal can offer a "copy
                    // trace_id → grep backend logs" affordance per request.
                    ...(traceIds ? { trace_id: traceIds.traceId, span_id: traceIds.spanId } : {}),
                    ...(mirrored
                        ? { triggered_by_element: tap.element, triggered_by_screen: tap.screen }
                        : {}),
                });
            }
        };
        wrapped.__unitrack_wrapped = true;
        global.fetch = wrapped;
    }
}
const UniTrack = new UniTrackClass();
/**
 * Auto-capture deeplinks via RN's Linking API. Call once at startup. Tracks the
 * launch URL (cold start) and every subsequent url event as `deeplink`.
 */
function installDeeplinkAutoCapture() {
    var _a, _b;
    // Lazy require so importing the SDK never hard-depends on Linking being set up.
    const { Linking } = require('react-native');
    (_a = Linking.getInitialURL) === null || _a === void 0 ? void 0 : _a.call(Linking).then((url) => {
        if (url)
            UniTrack.trackDeeplink(url, 'launch');
    }).catch(() => { });
    (_b = Linking.addEventListener) === null || _b === void 0 ? void 0 : _b.call(Linking, 'url', ({ url }) => {
        if (url)
            UniTrack.trackDeeplink(url, 'runtime');
    });
}
/**
 * Auto-capture outgoing URL opens via Linking.openURL — every time the app
 * launches Safari / Maps / Zalo / Telegram / a custom-scheme app, we emit
 * `third_party_open` BEFORE handing the URL to the OS. Classification
 * matches the iOS swizzler + Android helper (browser / phone / mail / sms /
 * <scheme>). Wraps once; subsequent calls are no-ops.
 */
function installThirdPartyOpenAutoCapture() {
    const { Linking } = require('react-native');
    if (!Linking || !Linking.openURL)
        return;
    if (Linking.openURL.__unitrack_wrapped)
        return;
    const orig = Linking.openURL.bind(Linking);
    const wrapped = (url) => {
        try {
            let scheme = '';
            try {
                scheme = (new URL(url).protocol || '').replace(/:$/, '').toLowerCase();
            }
            catch (_) { /* malformed — fall through */ }
            const target = scheme === 'http' || scheme === 'https' ? 'browser'
                : scheme === 'tel' ? 'phone'
                    : scheme === 'mailto' ? 'mail'
                        : scheme === 'sms' ? 'sms'
                            : (scheme || 'unknown');
            UniTrack.track('third_party_open', {
                target, url, ...(scheme ? { scheme } : {}),
            });
        }
        catch (_) { /* never block the launch */ }
        return orig(url);
    };
    wrapped.__unitrack_wrapped = true;
    Linking.openURL = wrapped;
}
exports.default = UniTrack;
var autoTap_1 = require("./autoTap");
Object.defineProperty(exports, "UniTrackTapBoundary", { enumerable: true, get: function () { return autoTap_1.UniTrackTapBoundary; } });
var tapState_2 = require("./tapState");
Object.defineProperty(exports, "tapState", { enumerable: true, get: function () { return tapState_2.tapState; } });
var navigation_1 = require("./navigation");
Object.defineProperty(exports, "createNavigationTracker", { enumerable: true, get: function () { return __importDefault(navigation_1).default; } });
var safeJsonParse_1 = require("./safeJsonParse");
Object.defineProperty(exports, "safeJsonParse", { enumerable: true, get: function () { return __importDefault(safeJsonParse_1).default; } });
//# sourceMappingURL=index.js.map
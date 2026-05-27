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
const react_native_1 = require("react-native");
const tapState_1 = require("./tapState");
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
        // Registered third-party providers (Snowplow, Firebase, …). Every event is
        // forwarded to each one. Empty by default — core has zero such dependencies.
        this.providers = [];
        // Event rewrite rules (Phase 2 — config-driven). A matching rule renames an
        // auto-captured event into a business event + merges props at this chokepoint.
        this.eventRules = [];
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
    setEventRules(rules) { this.eventRules = rules; }
    applyRules(event, props) {
        var _a;
        const screen = ((_a = props['screen']) !== null && _a !== void 0 ? _a : props['screen_name']);
        const elem = props['element_key'];
        for (const r of this.eventRules) {
            if (r.matchEvent !== event)
                continue;
            if (r.matchScreen && r.matchScreen !== screen)
                continue;
            if (r.matchElementKey && r.matchElementKey !== elem)
                continue;
            return [r.toName, { ...props, ...r.addProps }];
        }
        return null;
    }
    track(event, properties = {}) {
        let name = event;
        let props = properties;
        const rewritten = this.applyRules(event, properties);
        if (rewritten) {
            [name, props] = rewritten;
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
    // --- semantic event helpers (Phase 3) ----------------------------------
    /** Notification received/opened. state: 'foreground'|'background'|'silent'. */
    trackNotification(opts) {
        var _a;
        return this.track('notification', {
            state: opts.state, action: (_a = opts.action) !== null && _a !== void 0 ? _a : 'received',
            ...(opts.title ? { title: opts.title } : {}),
            ...(opts.body ? { body: opts.body } : {}),
            ...(opts.data ? { data: opts.data } : {}),
        });
    }
    trackWebViewOpen(url, screen) {
        return this.track('webview_open', { url: hostPath(url), ...(screen ? { screen } : {}) });
    }
    trackDeeplink(url, source) {
        return this.track('deeplink', { url: hostPath(url), ...(source ? { source } : {}) });
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
            try {
                const res = await orig(input, init);
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
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
exports.safeJsonParse = exports.createNavigationTracker = void 0;
const react_native_1 = require("react-native");
const LINK_HINT = `[UniTrack] Native module not found. ` +
    `Ensure '@unitrack/react-native' is properly linked. ` +
    `Run 'pod install' (iOS) and rebuild.`;
const native = (_a = react_native_1.NativeModules.UniTrack) !== null && _a !== void 0 ? _a : new Proxy({}, {
    get() {
        throw new Error(LINK_HINT);
    },
});
class UniTrackClass {
    constructor() {
        this.initialized = false;
    }
    async initialize(apiKey, config = {}) {
        if (this.initialized)
            return;
        await native.initialize(apiKey, JSON.stringify(config));
        this.initialized = true;
        this.installFetchInterceptor();
    }
    identify(userId, traits = {}) {
        return native.identify(userId, JSON.stringify(traits));
    }
    reset() { return native.reset(); }
    track(event, properties = {}) {
        return native.track(event, JSON.stringify(properties));
    }
    setScreen(name) { return native.setScreen(name); }
    flush() { return native.flush(); }
    setEnabled(e) { return native.setEnabled(e); }
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
                this.track('network_request', {
                    url: url.split('?')[0],
                    method,
                    status,
                    duration_ms: dur,
                    req_bytes: reqBytes,
                    resp_bytes: respBytes,
                    error: errMsg,
                });
            }
        };
        wrapped.__unitrack_wrapped = true;
        global.fetch = wrapped;
    }
}
const UniTrack = new UniTrackClass();
exports.default = UniTrack;
var navigation_1 = require("./navigation");
Object.defineProperty(exports, "createNavigationTracker", { enumerable: true, get: function () { return __importDefault(navigation_1).default; } });
var safeJsonParse_1 = require("./safeJsonParse");
Object.defineProperty(exports, "safeJsonParse", { enumerable: true, get: function () { return __importDefault(safeJsonParse_1).default; } });
//# sourceMappingURL=index.js.map
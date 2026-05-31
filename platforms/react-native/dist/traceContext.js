"use strict";
// W3C Trace Context for React Native.
//
// Why a JS-side generator (not the native core): minting two random numbers
// would cost a bridge round-trip per HTTP call (~1 ms on Android, more in
// debug). Spec only requires the ids be sufficiently random — crypto sources
// available in JS (react-native-get-random-values or expo-crypto, when the
// app provides them) are the same /dev/urandom / SecRandom the native core
// would use. We fall back to Math.random for environments without crypto;
// generated ids never feed auth or signing, so this is acceptable.
//
// Spec: https://www.w3.org/TR/trace-context/
var _a;
Object.defineProperty(exports, "__esModule", { value: true });
exports.tracingState = void 0;
exports.newTrace = newTrace;
exports.traceparentHeader = traceparentHeader;
exports.shouldInjectTrace = shouldInjectTrace;
exports.hostOf = hostOf;
// Mutable singleton config — readable by the fetch interceptor at request
// time. Single-threaded JS means no atomicity dance needed.
exports.tracingState = {
    current: {
        enabled: false,
        headerName: 'traceparent',
        allowlistHosts: [],
        sampled: true,
    },
};
// Use crypto.getRandomValues if the host environment provides it (the app
// usually polyfills via `react-native-get-random-values`). Otherwise fall
// back to Math.random — works for the spec's "random enough" requirement,
// but apps that care about cryptographic-grade ids should polyfill.
const _crypto = (_a = globalThis.crypto) !== null && _a !== void 0 ? _a : {};
function _randomBytes(n) {
    const out = new Uint8Array(n);
    if (_crypto.getRandomValues) {
        _crypto.getRandomValues(out);
        return out;
    }
    for (let i = 0; i < n; i++)
        out[i] = Math.floor(Math.random() * 256);
    return out;
}
function _toHex(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i++) {
        const b = bytes[i];
        s += (b < 16 ? '0' : '') + b.toString(16);
    }
    return s;
}
function _nonZeroBytes(n) {
    // Loop guards against the (astronomically unlikely) all-zero result, which
    // is invalid per W3C 3.2.2.5.
    for (;;) {
        const bytes = _randomBytes(n);
        for (let i = 0; i < bytes.length; i++) {
            if (bytes[i] !== 0)
                return bytes;
        }
    }
}
/** Mint a fresh (trace_id, span_id) pair — one root span per outbound call. */
function newTrace() {
    return {
        traceId: _toHex(_nonZeroBytes(16)), // 128-bit
        spanId: _toHex(_nonZeroBytes(8)), // 64-bit
    };
}
/** Format the W3C header value `00-<trace>-<span>-<flags>`. */
function traceparentHeader(ids, sampled = true) {
    return `00-${ids.traceId}-${ids.spanId}-${sampled ? '01' : '00'}`;
}
/**
 * Decide if a request to `host` may receive a `traceparent` header. Empty
 * allowlist = fail-closed: never inject — so `traceparent` doesn't leak to
 * Firebase / Maps / CDNs by default. Each entry is either an exact host or
 * `*.suffix.com` (matches every subdomain plus the bare apex).
 */
function shouldInjectTrace(host, allowlist) {
    if (!host || allowlist.length === 0)
        return false;
    const h = host.toLowerCase();
    for (const raw of allowlist) {
        const pat = raw.toLowerCase();
        if (pat === h)
            return true;
        if (pat.startsWith('*.')) {
            const suffix = pat.substring(1); // ".example.com"
            if (h.endsWith(suffix) || h === suffix.substring(1))
                return true;
        }
    }
    return false;
}
// Extract the host from a fetch input (URL string, URL, or Request).
function hostOf(input) {
    try {
        const s = typeof input === 'string'
            ? input
            : input instanceof URL ? input.toString() : input.url;
        return new URL(s).host;
    }
    catch (_) {
        return null;
    }
}
//# sourceMappingURL=traceContext.js.map
// W3C Trace Context generator for the Flutter binding.
//
// Why a Dart-side generator (instead of bouncing through MethodChannel into
// the C core that already does this): each HTTP request would need a
// platform round-trip just to mint two random numbers — that adds 0.5–1 ms
// per call on Android, multiplied across every API a screen makes. The
// spec only requires "sufficiently random" 128-bit/64-bit ids; Random.secure
// uses the OS CSPRNG (/dev/urandom or SecRandom), which is the same source
// the C core's random_device would tap. Same guarantees, no IPC.
//
// Spec: https://www.w3.org/TR/trace-context/

import 'dart:math';

class UniTrackTraceIds {
  final String traceId;   // 32 lowercase hex
  final String spanId;    // 16 lowercase hex
  const UniTrackTraceIds(this.traceId, this.spanId);
}

class UniTrackTraceContext {
  // Random.secure throws on platforms without a secure source. We catch in
  // newTrace() and fall back to a non-secure Random there — generator IDs
  // never feed into auth or signing, so this is acceptable.
  static final Random _rng = _safeRandom();
  static Random _safeRandom() {
    try { return Random.secure(); } catch (_) { return Random(); }
  }

  /// Mint a (trace_id, span_id) pair — one root span per outbound call.
  static UniTrackTraceIds newTrace() {
    // 128 bits = two 64-bit halves; loop guards against the (astronomically
    // unlikely) all-zero result, which is invalid per W3C 3.2.2.5.
    int hi = 0, lo = 0;
    while (hi == 0 && lo == 0) {
      hi = _u64();
      lo = _u64();
    }
    int span = 0;
    while (span == 0) span = _u64();
    return UniTrackTraceIds(_hex16(hi) + _hex16(lo), _hex16(span));
  }

  /// Format the W3C header value `00-<trace>-<span>-<flags>`.
  static String traceparent(UniTrackTraceIds ids, {bool sampled = true}) {
    return '00-${ids.traceId}-${ids.spanId}-${sampled ? "01" : "00"}';
  }

  /// Decide if a request to [host] may receive a `traceparent` header.
  /// Empty allowlist = fail-closed: never inject. Each entry is either
  /// `host.exact.com` or `*.suffix.com` (matches `api.suffix.com`,
  /// `cdn.suffix.com`, AND the bare `suffix.com`).
  static bool shouldInject(String? host, List<String> allowlist) {
    if (host == null || host.isEmpty || allowlist.isEmpty) return false;
    final h = host.toLowerCase();
    for (final raw in allowlist) {
      final pat = raw.toLowerCase();
      if (pat == h) return true;
      if (pat.startsWith('*.')) {
        final suffix = pat.substring(1);                // ".example.com"
        if (h.endsWith(suffix) || h == suffix.substring(1)) return true;
      }
    }
    return false;
  }

  // ── helpers ────────────────────────────────────────────────────────────
  // Random.nextInt caps at 1 << 32 on the web target, so build a 64-bit int
  // from two 32-bit halves. On VM ints are 64-bit native so this is cheap.
  static int _u64() => (_rng.nextInt(1 << 32) << 32) | _rng.nextInt(1 << 32);

  static String _hex16(int v) {
    // Mask to 64-bit (safe on web where ints are doubles) and emit 16 lowercase
    // hex chars (zero-padded). Built by hand because radixString skips leading
    // zeros, which would corrupt the W3C header length.
    final masked = v & 0xFFFFFFFFFFFFFFFF;
    final s = masked.toRadixString(16);
    return s.length >= 16 ? s.substring(s.length - 16) : s.padLeft(16, '0');
  }
}

/// Runtime tracing settings, fed from remote config. Holds enabled flag, the
/// header name, the host allowlist (fail-closed when empty), and the sampled
/// flag. Replaced atomically by [setTracing]; HTTP interceptor reads the
/// current value at request time.
class UniTrackTracingConfig {
  final bool enabled;
  final String headerName;
  final List<String> allowlistHosts;
  final bool sampled;
  const UniTrackTracingConfig({
    this.enabled = false,
    this.headerName = 'traceparent',
    this.allowlistHosts = const [],
    this.sampled = true,
  });
}

/// Mutable holder accessible from the HTTP interceptor. Volatility isn't a
/// concern in Dart (single isolate), so a plain field is sufficient — the
/// reader is in the same isolate as the writer.
UniTrackTracingConfig unitrackTracing = const UniTrackTracingConfig();

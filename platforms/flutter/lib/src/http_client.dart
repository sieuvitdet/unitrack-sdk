// UniTrackHttpClient — wrapper http.BaseClient inject W3C traceparent header
// + emit network_request event (cùng trace_id) cho mọi outbound HTTP của Dart.
//
// Tại sao cần file này: Flutter Dart HTTP (package:http, dio, ...) KHÔNG đi
// qua URLProtocol native iOS / OkHttp interceptor Android — engine Dart có
// network stack riêng. Native UniTrackURLProtocol chỉ bắt được URLSession
// native; Flutter Dart calls đi qua Dart::IO socket → invisible với SDK
// native. Hậu quả: trace_id native + Flutter KHÔNG link với nhau, network
// timeline Portal thiếu Flutter calls.
//
// Cơ chế:
//   1. Wrap http.Client thành UniTrackHttpClient. Mọi request đi qua send().
//   2. Pre-flight: nếu config.tracing.enabled + host khớp allowlist → mint
//      trace_id/span_id qua UniTrackTraceContext, set header "traceparent"
//      (tên header sửa được qua config).
//   3. Sau response: UniTrack.track("network_request", {url, method, status,
//      duration_ms, trace_id, span_id, ...}). Native side cũng emit cùng
//      event_name nên Portal merge được — phân biệt qua field "framework"
//      = "flutter" (Dart) vs "uikit"/"android" (native).
//
// Cách dùng (DEV side):
//   final client = UniTrackHttpClient(http.Client());
//   // Hoặc dùng default ko cần inner:
//   final client = UniTrackHttpClient.create();
//   final resp = await client.get(Uri.parse('https://api...'));
//
//   // Với dio: dùng UniTrackDioInterceptor (file kế tiếp).
//
// Khi `UniTrack.setTracing(enabled: false)` → no-op. Khi allowlist empty
// (fail-closed default) → vẫn emit network_request nhưng KHÔNG inject
// trace header (chống leak traceparent ra 3rd-party).

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../unitrack.dart';

class UniTrackHttpClient extends http.BaseClient {
  final http.Client _inner;
  final bool _ownInner;

  /// Wrap an existing client (preferred — DEV may have custom client config
  /// vd certificate pinning, proxy, …). Caller owns `inner.close()`.
  UniTrackHttpClient(http.Client inner)
      : _inner = inner,
        _ownInner = false;

  /// Convenience constructor — creates an inner `http.Client()`. Caller
  /// must call `close()` to release the underlying client.
  factory UniTrackHttpClient.create() =>
      UniTrackHttpClient._owned(http.Client());

  UniTrackHttpClient._owned(http.Client inner)
      : _inner = inner,
        _ownInner = true;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stopwatch = Stopwatch()..start();

    // Snapshot tracing config — read once per request, vì Portal có thể save
    // cấu hình giữa burst HTTP → dùng snapshot tránh inject 1 phần.
    final tracing = UniTrack.instance.tracingSnapshot();
    UniTrackTraceIds? traceIds;
    final host = request.url.host;

    if (tracing.enabled &&
        UniTrackTraceContext.shouldInject(host, tracing.allowlistHosts) &&
        !request.headers.containsKey(tracing.headerName)) {
      traceIds = UniTrackTraceContext.newTrace();
      final header =
          UniTrackTraceContext.traceparent(traceIds, sampled: tracing.sampled);
      request.headers[tracing.headerName] = header;
      if (kDebugMode) {
        debugPrint('[W3C/dart] inject host=$host ${tracing.headerName}: $header');
      }
    } else if (tracing.enabled && kDebugMode) {
      final reason = !UniTrackTraceContext.shouldInject(host, tracing.allowlistHosts)
          ? 'host not in allowlist'
          : 'header already set by app';
      debugPrint('[W3C/dart] skip   host=$host reason=$reason');
    }

    http.StreamedResponse? response;
    String? errorDesc;
    try {
      response = await _inner.send(request);
      return response;
    } catch (e) {
      errorDesc = e.toString();
      rethrow;
    } finally {
      stopwatch.stop();
      // Emit network_request event với cùng trace_id đã inject. Portal khớp
      // với native event (cùng convention name) — operator filter framework=flutter
      // để biệt lập Flutter calls.
      final props = <String, dynamic>{
        'url':         _redactedUrl(request.url),
        'method':      request.method,
        'status':      response?.statusCode ?? 0,
        'duration_ms': stopwatch.elapsedMilliseconds,
        'req_bytes':   request.contentLength ?? 0,
        'resp_bytes':  response?.contentLength ?? 0,
        'error':       errorDesc ?? '',
        'framework':   'flutter',
      };
      if (traceIds != null) {
        props['trace_id'] = traceIds.traceId;
        props['span_id']  = traceIds.spanId;
      }
      // Fire-and-forget — không await để latency request không bị tăng.
      // ignore: discarded_futures
      UniTrack.instance.track('network_request', properties: props);
    }
  }

  /// Strip query string and fragment — same redaction native iOS does.
  /// Header `Authorization` cũng không log (mặc định không có trong props).
  String _redactedUrl(Uri u) {
    return Uri(
      scheme: u.scheme,
      host:   u.host,
      port:   u.hasPort ? u.port : null,
      path:   u.path,
    ).toString();
  }

  @override
  void close() {
    if (_ownInner) _inner.close();
    super.close();
  }
}

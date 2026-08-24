// Patch global fetch + XMLHttpRequest.prototype để:
//   1. Inject `traceparent` W3C header cho host trong allowlist.
//   2. Emit `network_request` / `network_error` event sau khi response về.
//
// Cẩn thận:
// - Mất event tracking call của chính SDK → exclude URL ingest qua substring.
// - CORS: BE phải `Access-Control-Allow-Headers: traceparent` mới nhận được
//   header. Nếu không → preflight fail, request không gửi được.

import { formatTraceparent, newTrace, shouldInject } from './trace-context';

type Emit = (name: string, props: Record<string, unknown>) => void;

interface NetworkOptions {
  trackNetwork: boolean;
  tracingAllowlistHosts: string[];
  excludeSubstrings: string[];     // URL chứa substring nào sẽ KHÔNG track
  networkEventName: string;        // default 'network_request'
  errorEventName: string;          // default 'network_error'
}

let installed = false;

export function installNetworkInterceptor(opts: NetworkOptions, emit: Emit): void {
  if (installed) return;
  installed = true;
  if (!opts.trackNetwork && opts.tracingAllowlistHosts.length === 0) return;

  patchFetch(opts, emit);
  patchXHR(opts, emit);
}

// ─── fetch ──────────────────────────────────────────────────────────────

function patchFetch(opts: NetworkOptions, emit: Emit): void {
  const origFetch = window.fetch;
  if (!origFetch) return;
  window.fetch = async function (input: RequestInfo | URL, init?: RequestInit) {
    const url = typeof input === 'string' ? input
              : input instanceof URL ? input.toString()
              : (input as Request).url;
    if (isExcluded(url, opts.excludeSubstrings)) {
      return origFetch.call(this, input, init);
    }

    // Inject traceparent nếu host nằm trong allowlist.
    let traceId: string | undefined;
    if (opts.tracingAllowlistHosts.length > 0) {
      const host = safeHost(url);
      if (shouldInject(host, opts.tracingAllowlistHosts)) {
        const ids = newTrace();
        traceId = ids.traceId;
        const headers = new Headers(init?.headers || {});
        headers.set('traceparent', formatTraceparent(ids));
        init = { ...(init || {}), headers };
      }
    }

    const startTime = performance.now();
    const method = (init?.method || (input as Request).method || 'GET').toUpperCase();
    try {
      const res = await origFetch.call(this, input, init);
      if (opts.trackNetwork) {
        emit(opts.networkEventName, {
          url: stripQuery(url),
          method,
          status_code: res.status,
          duration_ms: Math.round(performance.now() - startTime),
          ok: res.ok,
          trace_id: traceId,
        });
      }
      return res;
    } catch (err) {
      if (opts.trackNetwork) {
        emit(opts.errorEventName, {
          url: stripQuery(url),
          method,
          duration_ms: Math.round(performance.now() - startTime),
          error: String((err as Error)?.message || err),
          trace_id: traceId,
        });
      }
      throw err;
    }
  };
}

// ─── XMLHttpRequest ─────────────────────────────────────────────────────

function patchXHR(opts: NetworkOptions, emit: Emit): void {
  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  const origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

  XMLHttpRequest.prototype.open = function (...args: unknown[]) {
    const method = String(args[0] || 'GET').toUpperCase();
    const url = String(args[1] || '');
    (this as any).__ut_method = method;
    (this as any).__ut_url = url;
    return origOpen.apply(this, args as Parameters<typeof origOpen>);
  };

  XMLHttpRequest.prototype.send = function (body?: Document | XMLHttpRequestBodyInit | null) {
    const url: string = (this as any).__ut_url || '';
    const method: string = (this as any).__ut_method || 'GET';
    if (isExcluded(url, opts.excludeSubstrings)) {
      return origSend.call(this, body);
    }

    // Inject traceparent
    let traceId: string | undefined;
    if (opts.tracingAllowlistHosts.length > 0) {
      const host = safeHost(url);
      if (shouldInject(host, opts.tracingAllowlistHosts)) {
        const ids = newTrace();
        traceId = ids.traceId;
        try {
          origSetRequestHeader.call(this, 'traceparent', formatTraceparent(ids));
        } catch { /* readyState != OPENED */ }
      }
    }

    const startTime = performance.now();
    const xhr = this;
    const handler = () => {
      if (xhr.readyState !== 4) return;
      if (opts.trackNetwork) {
        const isError = xhr.status === 0 || xhr.status >= 400;
        emit(isError ? opts.errorEventName : opts.networkEventName, {
          url: stripQuery(url),
          method,
          status_code: xhr.status,
          duration_ms: Math.round(performance.now() - startTime),
          trace_id: traceId,
        });
      }
      xhr.removeEventListener('readystatechange', handler);
    };
    xhr.addEventListener('readystatechange', handler);
    return origSend.call(this, body);
  };
}

// ─── Helpers ────────────────────────────────────────────────────────────

function isExcluded(url: string, excludes: string[]): boolean {
  if (!excludes.length) return false;
  return excludes.some((s) => url.includes(s));
}

function safeHost(url: string): string | null {
  try {
    const u = new URL(url, window.location.href);
    return u.host;
  } catch {
    return null;
  }
}

function stripQuery(url: string): string {
  try {
    const u = new URL(url, window.location.href);
    return `${u.protocol}//${u.host}${u.pathname}`;
  } catch {
    return url.split('?')[0] || url;
  }
}

// W3C Trace Context — mint trace_id/span_id, format `traceparent` header,
// fail-closed allowlist match. Port từ Flutter `src/trace_context.dart`.
//
// Spec: https://www.w3.org/TR/trace-context/

import type { TraceIds } from './types';

/** Sinh cặp (trace_id, span_id) mới — 1 root span per outbound call. */
export function newTrace(): TraceIds {
  return {
    traceId: randomHex(32),
    spanId: randomHex(16),
  };
}

/** Format `traceparent` header value: "00-<trace>-<span>-<flags>" (55 chars). */
export function formatTraceparent(ids: TraceIds, sampled = true): string {
  const flags = sampled ? '01' : '00';
  return `00-${ids.traceId}-${ids.spanId}-${flags}`;
}

/** Có inject traceparent vào request đến `host` không?
 *
 * Empty allowlist = fail-closed (KHÔNG inject) — tránh leak header sang
 * 3rd-party API (Firebase, Google Maps, CDN ảnh).
 *
 * Mỗi entry là exact host (`api.example.com`) hoặc wildcard suffix
 * (`*.example.com` match mọi subdomain + apex). */
export function shouldInject(host: string | null, allowlist: string[]): boolean {
  if (!host || allowlist.length === 0) return false;
  const h = host.toLowerCase();
  for (const raw of allowlist) {
    const entry = raw.trim().toLowerCase();
    if (!entry) continue;
    if (entry.startsWith('*.')) {
      const suffix = entry.slice(2);
      if (h === suffix || h.endsWith('.' + suffix)) return true;
    } else if (h === entry) {
      return true;
    }
  }
  return false;
}

function randomHex(len: number): string {
  // crypto.getRandomValues là cryptographic-grade — đủ entropy cho trace_id
  // join logs giữa frontend + backend (không phải security primitive).
  const bytes = new Uint8Array(len / 2);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < bytes.length; i++) bytes[i] = (Math.random() * 256) | 0;
  }
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

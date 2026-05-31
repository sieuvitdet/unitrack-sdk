export interface UniTrackTraceIds {
    traceId: string;
    spanId: string;
}
export interface UniTrackTracingConfig {
    enabled: boolean;
    headerName: string;
    allowlistHosts: string[];
    sampled: boolean;
}
export declare const tracingState: {
    current: UniTrackTracingConfig;
};
/** Mint a fresh (trace_id, span_id) pair — one root span per outbound call. */
export declare function newTrace(): UniTrackTraceIds;
/** Format the W3C header value `00-<trace>-<span>-<flags>`. */
export declare function traceparentHeader(ids: UniTrackTraceIds, sampled?: boolean): string;
/**
 * Decide if a request to `host` may receive a `traceparent` header. Empty
 * allowlist = fail-closed: never inject — so `traceparent` doesn't leak to
 * Firebase / Maps / CDNs by default. Each entry is either an exact host or
 * `*.suffix.com` (matches every subdomain plus the bare apex).
 */
export declare function shouldInjectTrace(host: string | null | undefined, allowlist: string[]): boolean;
export declare function hostOf(input: RequestInfo | URL): string | null;
//# sourceMappingURL=traceContext.d.ts.map
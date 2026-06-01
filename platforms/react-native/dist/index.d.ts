import { type UniTrackTraceIds, type UniTrackTracingConfig } from './traceContext';
export interface UniTrackConfig {
    endpoint?: string;
    batchSize?: number;
    flushIntervalMs?: number;
    samplingRate?: number;
    autoCapture?: boolean;
    trackScreens?: boolean;
    trackTaps?: boolean;
    trackNetwork?: boolean;
    /** Emit session_start/session_end boundaries so the portal can reconstruct
     *  each session's journey. */
    journeyCapture?: boolean;
    /** Inactivity/background window (ms) after which a session is closed. */
    sessionTimeoutMs?: number;
}
export type EventProperties = Record<string, unknown>;
/** A config-driven rewrite rule: when an auto-captured event matches, the SDK
 *  renames it to `toName` and merges `addProps`. Built from the remote config. */
export interface EventRule {
    matchEvent: string;
    matchScreen?: string;
    matchElementKey?: string;
    toName: string;
    addProps?: EventProperties;
}
import type { AnalyticsProvider } from './analyticsProvider';
export { UniTrackRemoteConfig } from './remoteConfig';
export type { AnalyticsProvider } from './analyticsProvider';
declare class UniTrackClass {
    private initialized;
    private readonly bootAt;
    private providers;
    /** Register a provider to also receive every event. Call BEFORE initialize();
     *  if called afterwards, the provider is initialized immediately. */
    addProvider(provider: AnalyticsProvider): void;
    private forEachProvider;
    initialize(apiKey: string, config?: UniTrackConfig): Promise<void>;
    identify(userId: string, traits?: EventProperties): Promise<void>;
    reset(): Promise<void>;
    private eventRules;
    setEventRules(rules: EventRule[]): void;
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
    setTracing(opts: Partial<UniTrackTracingConfig> & {
        enabled: boolean;
    }): void;
    /** Mint a fresh (trace_id, span_id) — exposed so app code can correlate
     *  push payloads or deep-links with backend logs by trace_id. */
    newTrace(): UniTrackTraceIds;
    private applyRules;
    track(event: string, properties?: EventProperties): Promise<void>;
    setScreen(name: string): Promise<void>;
    flush(): Promise<void>;
    setEnabled(e: boolean): Promise<void>;
    /** Notification received/opened/dismissed.
     *  state: 'foreground'|'background'|'silent'
     *  action: 'received'|'opened'|'dismissed' (default 'received')
     *  notificationId: platform id (FCM messageId / APNs id) so the portal can
     *    dedup the same push across deliver/open
     *  data: raw payload (usually carries routing keys like deeplink/campaign_id)
     */
    trackNotification(opts: {
        state: string;
        action?: string;
        title?: string;
        body?: string;
        notificationId?: string;
        data?: EventProperties;
    }): Promise<void>;
    trackWebViewOpen(url: string, screen?: string): Promise<void>;
    /** A deeplink / universal link opened the app or a screen.
     *  Adds scheme/host/path/query separately + is_cold flag (true when fired
     *  within 5s of module load = the link launched the app). */
    trackDeeplink(url: string, source?: string): Promise<void>;
    trackThirdPartyOpen(name: string, screen?: string): Promise<void>;
    /**
     * Install global fetch interceptor for network tracking at the JS layer.
     * Native auto-capture on iOS already covers URLSession, but RN's fetch
     * goes through its own networking stack — this catches JS-side calls.
     */
    private installFetchInterceptor;
}
declare const UniTrack: UniTrackClass;
/**
 * Auto-capture deeplinks via RN's Linking API. Call once at startup. Tracks the
 * launch URL (cold start) and every subsequent url event as `deeplink`.
 */
export declare function installDeeplinkAutoCapture(): void;
export default UniTrack;
export { UniTrackTapBoundary } from './autoTap';
export { tapState } from './tapState';
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';
//# sourceMappingURL=index.d.ts.map
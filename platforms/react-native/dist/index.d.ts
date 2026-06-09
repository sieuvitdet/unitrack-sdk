import { type EmitterSubscription } from 'react-native';
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
    private eventNames;
    setEventNames(map: Record<string, string>): void;
    private resolveKind;
    private kindForRawEvent;
    track(event: string, properties?: EventProperties): Promise<void>;
    setScreen(name: string): Promise<void>;
    flush(): Promise<void>;
    setEnabled(e: boolean): Promise<void>;
    /** UUID of the active session — empty before init. */
    currentSessionId(): Promise<string>;
    /** Lifetime session counter (persists across launches). 1 on first
     *  install, +1 per timeout-driven rotation. */
    sessionIndex(): Promise<number>;
    /** UUID of the session that just closed; empty on the first session after
     *  install. Pair with [currentSessionId] when emitting session_started. */
    previousSessionId(): Promise<string>;
    /** Force a session rotation now. Bumps sessionIndex, mints a new UUID,
     *  records the just-closed UUID as previousSessionId. Use on logout /
     *  switch-account / new-context boundaries when the inactivity timeout
     *  isn't enough. */
    rotateSession(): Promise<void>;
    /** Snapshot of events still sitting in the SQLite offline queue, grouped
     *  by raw event_name. Used by debug toasts during airplane-mode testing:
     *  `Saved 7 ev_screen_view, 3 ev_click`. Empty before init or queue empty. */
    pendingEventCounts(): Promise<Record<string, number>>;
    private flushEmitter;
    private flushSubscribers;
    /** Fires after each successful batch upload with the per-event_name
     *  breakdown of THAT batch (vd `{ev_click: 3, ev_result: 2}`). Returns
     *  an [EmitterSubscription]; call `.remove()` when you're done so the
     *  native worker stops posting if no other listener remains. */
    onFlushCompleted(handler: (counts: Record<string, number>) => void): EmitterSubscription;
    /** Device/app metadata bag captured at init (platform, app_version,
     *  network_*, device_*). Same dict the native Snowplow provider uses to
     *  build its `application_context` entity. Empty before init. */
    applicationContext(): Promise<Record<string, unknown>>;
    /** Resolve a runtime value. Resolution order:
     *    1. Portal `sdk_config.custom_values[key]`
     *    2. Any registered remote-value provider (Firebase RC)
     *    3. [defaultValue]
     *
     *  T may be `string | number | boolean`. Coercion happens on the native
     *  side based on the type of [defaultValue]. */
    getRemoteValue<T extends string | number | boolean>(key: string, defaultValue: T): Promise<T>;
    sessionScreenCount(): Promise<number>;
    sessionHadError(): Promise<boolean>;
    sessionHadCrash(): Promise<boolean>;
    incrementScreenCount(): Promise<void>;
    markSessionError(): Promise<void>;
    markSessionCrash(): Promise<void>;
    resetSessionStats(): Promise<void>;
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
/**
 * Auto-capture outgoing URL opens via Linking.openURL — every time the app
 * launches Safari / Maps / Zalo / Telegram / a custom-scheme app, we emit
 * `third_party_open` BEFORE handing the URL to the OS. Classification
 * matches the iOS swizzler + Android helper (browser / phone / mail / sms /
 * <scheme>). Wraps once; subsequent calls are no-ops.
 */
export declare function installThirdPartyOpenAutoCapture(): void;
export default UniTrack;
export { UniTrackTapBoundary } from './autoTap';
export { tapState } from './tapState';
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';
//# sourceMappingURL=index.d.ts.map
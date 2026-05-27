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
    private applyRules;
    track(event: string, properties?: EventProperties): Promise<void>;
    setScreen(name: string): Promise<void>;
    flush(): Promise<void>;
    setEnabled(e: boolean): Promise<void>;
    /** Notification received/opened. state: 'foreground'|'background'|'silent'. */
    trackNotification(opts: {
        state: string;
        action?: string;
        title?: string;
        body?: string;
        data?: EventProperties;
    }): Promise<void>;
    trackWebViewOpen(url: string, screen?: string): Promise<void>;
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
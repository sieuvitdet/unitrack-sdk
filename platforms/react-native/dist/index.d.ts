export interface UniTrackConfig {
    endpoint?: string;
    batchSize?: number;
    flushIntervalMs?: number;
    samplingRate?: number;
    autoCapture?: boolean;
    trackScreens?: boolean;
    trackTaps?: boolean;
    trackNetwork?: boolean;
}
export type EventProperties = Record<string, unknown>;
declare class UniTrackClass {
    private initialized;
    initialize(apiKey: string, config?: UniTrackConfig): Promise<void>;
    identify(userId: string, traits?: EventProperties): Promise<void>;
    reset(): Promise<void>;
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
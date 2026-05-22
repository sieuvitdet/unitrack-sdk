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
    /**
     * Install global fetch interceptor for network tracking at the JS layer.
     * Native auto-capture on iOS already covers URLSession, but RN's fetch
     * goes through its own networking stack — this catches JS-side calls.
     */
    private installFetchInterceptor;
}
declare const UniTrack: UniTrackClass;
export default UniTrack;
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';
//# sourceMappingURL=index.d.ts.map
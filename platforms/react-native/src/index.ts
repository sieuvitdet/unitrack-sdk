// @unitrack/react-native
//
// Public API. Calls the native module which forwards to the iOS / Android
// SDK installed underneath. Auto-capture (screens, taps, network) is
// configured on the native side; React Navigation hooks add JS-level
// screen tracking on top.

import { NativeModules, Platform } from 'react-native';

interface NativeAPI {
  initialize(apiKey: string, config: string): Promise<void>;
  identify(userId: string, traitsJson: string): Promise<void>;
  reset(): Promise<void>;
  track(event: string, propsJson: string): Promise<void>;
  setScreen(name: string): Promise<void>;
  flush(): Promise<void>;
  setEnabled(enabled: boolean): Promise<void>;
}

const LINK_HINT =
  `[UniTrack] Native module not found. ` +
  `Ensure '@unitrack/react-native' is properly linked. ` +
  `Run 'pod install' (iOS) and rebuild.`;

const native: NativeAPI =
  (NativeModules.UniTrack as NativeAPI) ??
  new Proxy({} as NativeAPI, {
    get() {
      throw new Error(LINK_HINT);
    },
  });

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

class UniTrackClass {
  private initialized = false;

  async initialize(apiKey: string, config: UniTrackConfig = {}): Promise<void> {
    if (this.initialized) return;
    await native.initialize(apiKey, JSON.stringify(config));
    this.initialized = true;
    this.installFetchInterceptor();
  }

  identify(userId: string, traits: EventProperties = {}) {
    return native.identify(userId, JSON.stringify(traits));
  }

  reset() { return native.reset(); }

  track(event: string, properties: EventProperties = {}) {
    return native.track(event, JSON.stringify(properties));
  }

  setScreen(name: string) { return native.setScreen(name); }
  flush()                 { return native.flush(); }
  setEnabled(e: boolean)  { return native.setEnabled(e); }

  /**
   * Install global fetch interceptor for network tracking at the JS layer.
   * Native auto-capture on iOS already covers URLSession, but RN's fetch
   * goes through its own networking stack — this catches JS-side calls.
   */
  private installFetchInterceptor() {
    const orig = global.fetch;
    if (!orig || (orig as any).__unitrack_wrapped) return;

    const wrapped: typeof fetch = async (input, init) => {
      const start  = Date.now();
      const url    = typeof input === 'string' ? input :
                     input instanceof URL ? input.toString() : input.url;
      const method = init?.method ?? 'GET';
      let status = 0, respBytes = 0, errMsg = '';

      try {
        const res = await orig(input, init);
        status = res.status;
        const cl = res.headers.get('content-length');
        if (cl) respBytes = parseInt(cl, 10) || 0;
        return res;
      } catch (e: any) {
        errMsg = String(e?.message ?? e);
        throw e;
      } finally {
        const dur = Date.now() - start;
        const reqBody = init?.body;
        const reqBytes = typeof reqBody === 'string' ? reqBody.length : 0;
        this.track('network_request', {
          url: url.split('?')[0],
          method,
          status,
          duration_ms: dur,
          req_bytes:  reqBytes,
          resp_bytes: respBytes,
          error: errMsg,
        });
      }
    };
    (wrapped as any).__unitrack_wrapped = true;
    global.fetch = wrapped;
  }
}

const UniTrack = new UniTrackClass();
export default UniTrack;
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';

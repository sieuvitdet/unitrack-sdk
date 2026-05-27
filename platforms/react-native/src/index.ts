// @unitrack/react-native
//
// Public API. Calls the native module which forwards to the iOS / Android
// SDK installed underneath. Auto-capture (screens, taps, network) is
// configured on the native side; React Navigation hooks add JS-level
// screen tracking on top.

import { NativeModules, Platform } from 'react-native';
import { tapState } from './tapState';

// Strip query strings for privacy — log scheme://host/path only.
function hostPath(url: string): string {
  const m = /^([a-z][a-z0-9+.-]*:\/\/[^/?#]+)([^?#]*)/i.exec(url);
  return m ? m[1] + m[2] : url.split('?')[0];
}

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

class UniTrackClass {
  private initialized = false;

  // Registered third-party providers (Snowplow, Firebase, …). Every event is
  // forwarded to each one. Empty by default — core has zero such dependencies.
  private providers: AnalyticsProvider[] = [];

  /** Register a provider to also receive every event. Call BEFORE initialize();
   *  if called afterwards, the provider is initialized immediately. */
  addProvider(provider: AnalyticsProvider) {
    this.providers.push(provider);
    if (this.initialized) {
      Promise.resolve(provider.initialize()).catch((e) =>
        console.warn('[UniTrack] provider init failed', e),
      );
    }
  }

  // Run an action against every provider, isolating failures.
  private forEachProvider(action: (p: AnalyticsProvider) => void) {
    for (const p of this.providers) {
      try {
        action(p);
      } catch (e) {
        console.warn('[UniTrack] provider forward failed', e);
      }
    }
  }

  async initialize(apiKey: string, config: UniTrackConfig = {}): Promise<void> {
    if (this.initialized) return;
    await native.initialize(apiKey, JSON.stringify(config));
    this.initialized = true;
    this.installFetchInterceptor();
    // Bring up any providers registered before initialize().
    for (const p of this.providers) {
      try {
        await p.initialize();
      } catch (e) {
        console.warn('[UniTrack] provider init failed', e);
      }
    }
  }

  identify(userId: string, traits: EventProperties = {}) {
    this.forEachProvider((p) => p.setUser(userId, traits));
    return native.identify(userId, JSON.stringify(traits));
  }

  reset() {
    this.forEachProvider((p) => p.setUser(null, {}));
    return native.reset();
  }

  // Event rewrite rules (Phase 2 — config-driven). A matching rule renames an
  // auto-captured event into a business event + merges props at this chokepoint.
  private eventRules: EventRule[] = [];
  setEventRules(rules: EventRule[]) { this.eventRules = rules; }

  private applyRules(event: string, props: EventProperties): [string, EventProperties] | null {
    const screen = (props['screen'] ?? props['screen_name']) as string | undefined;
    const elem = props['element_key'] as string | undefined;
    for (const r of this.eventRules) {
      if (r.matchEvent !== event) continue;
      if (r.matchScreen && r.matchScreen !== screen) continue;
      if (r.matchElementKey && r.matchElementKey !== elem) continue;
      return [r.toName, { ...props, ...r.addProps }];
    }
    return null;
  }

  track(event: string, properties: EventProperties = {}) {
    let name = event;
    let props = properties;
    const rewritten = this.applyRules(event, properties);
    if (rewritten) { [name, props] = rewritten; }
    this.forEachProvider((p) => p.track(name, props));
    return native.track(name, JSON.stringify(props));
  }

  setScreen(name: string) {
    this.forEachProvider((p) => p.setScreen(name));
    return native.setScreen(name);
  }
  flush()                 { return native.flush(); }
  setEnabled(e: boolean)  { return native.setEnabled(e); }

  // --- semantic event helpers (Phase 3) ----------------------------------
  /** Notification received/opened. state: 'foreground'|'background'|'silent'. */
  trackNotification(opts: { state: string; action?: string; title?: string; body?: string; data?: EventProperties }) {
    return this.track('notification', {
      state: opts.state, action: opts.action ?? 'received',
      ...(opts.title ? { title: opts.title } : {}),
      ...(opts.body ? { body: opts.body } : {}),
      ...(opts.data ? { data: opts.data } : {}),
    });
  }
  trackWebViewOpen(url: string, screen?: string) {
    return this.track('webview_open', { url: hostPath(url), ...(screen ? { screen } : {}) });
  }
  trackDeeplink(url: string, source?: string) {
    return this.track('deeplink', { url: hostPath(url), ...(source ? { source } : {}) });
  }
  trackThirdPartyOpen(name: string, screen?: string) {
    return this.track('third_party_open', { target: name, ...(screen ? { screen } : {}) });
  }

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
        // Mirror the button/screen that triggered this call (set by the tap
        // boundary), so an API error can be traced back to its button + screen.
        const tap = tapState.last;
        const mirrored = tap && Date.now() - tap.at < 10_000;
        this.track('network_request', {
          url: url.split('?')[0],
          method,
          status,
          duration_ms: dur,
          req_bytes:  reqBytes,
          resp_bytes: respBytes,
          error: errMsg,
          ...(mirrored
            ? { triggered_by_element: tap!.element, triggered_by_screen: tap!.screen }
            : {}),
        });
      }
    };
    (wrapped as any).__unitrack_wrapped = true;
    global.fetch = wrapped;
  }
}

const UniTrack = new UniTrackClass();

/**
 * Auto-capture deeplinks via RN's Linking API. Call once at startup. Tracks the
 * launch URL (cold start) and every subsequent url event as `deeplink`.
 */
export function installDeeplinkAutoCapture() {
  // Lazy require so importing the SDK never hard-depends on Linking being set up.
  const { Linking } = require('react-native');
  Linking.getInitialURL?.().then((url: string | null) => {
    if (url) UniTrack.trackDeeplink(url, 'launch');
  }).catch(() => {});
  Linking.addEventListener?.('url', ({ url }: { url: string }) => {
    if (url) UniTrack.trackDeeplink(url, 'runtime');
  });
}

export default UniTrack;
export { UniTrackTapBoundary } from './autoTap';
export { tapState } from './tapState';
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';

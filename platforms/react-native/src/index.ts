// @unitrack/react-native
//
// Public API. Calls the native module which forwards to the iOS / Android
// SDK installed underneath. Auto-capture (screens, taps, network) is
// configured on the native side; React Navigation hooks add JS-level
// screen tracking on top.

import { NativeModules, Platform } from 'react-native';
import { tapState } from './tapState';
import {
  tracingState, newTrace, traceparentHeader, shouldInjectTrace, hostOf,
  type UniTrackTraceIds, type UniTrackTracingConfig,
} from './traceContext';

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

  // Set once at module load — used by trackDeeplink to decide `is_cold`.
  // (Module load runs during the React Native bridge boot, so deeplinks that
  // launch the app via Linking.getInitialURL fire within the first few seconds
  // of this timestamp.)
  private readonly bootAt: number = Date.now();

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
  setTracing(opts: Partial<UniTrackTracingConfig> & { enabled: boolean }) {
    tracingState.current = {
      enabled: opts.enabled,
      headerName: opts.headerName ?? 'traceparent',
      allowlistHosts: opts.allowlistHosts ?? [],
      sampled: opts.sampled ?? true,
    };
  }

  /** Mint a fresh (trace_id, span_id) — exposed so app code can correlate
   *  push payloads or deep-links with backend logs by trace_id. */
  newTrace(): UniTrackTraceIds { return newTrace(); }

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
  }) {
    return this.track('notification', {
      state: opts.state, action: opts.action ?? 'received',
      ...(opts.title ? { title: opts.title } : {}),
      ...(opts.body ? { body: opts.body } : {}),
      ...(opts.notificationId ? { notification_id: opts.notificationId } : {}),
      ...(opts.data ? { data: opts.data } : {}),
    });
  }
  trackWebViewOpen(url: string, screen?: string) {
    return this.track('webview_open', { url: hostPath(url), ...(screen ? { screen } : {}) });
  }
  /** A deeplink / universal link opened the app or a screen.
   *  Adds scheme/host/path/query separately + is_cold flag (true when fired
   *  within 5s of module load = the link launched the app). */
  trackDeeplink(url: string, source?: string) {
    const props: EventProperties = { url };
    try {
      const u = new URL(url);
      if (u.protocol) props.scheme = u.protocol.replace(/:$/, '');
      if (u.host)     props.host   = u.host;
      if (u.pathname) props.path   = u.pathname;
      if (u.search)   props.query  = u.search.replace(/^\?/, '');
    } catch (_) { /* malformed — keep just the raw URL */ }
    if (source) props.source = source;
    props.is_cold = Date.now() - this.bootAt <= 5_000;
    return this.track('deeplink', props);
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

      // W3C tracing: mint a (trace_id, span_id) if enabled AND host is
      // allowlisted AND the caller hasn't already set the header. We mutate a
      // local headers Map (Headers constructor handles all 3 input shapes:
      // plain object, [string,string][], or another Headers).
      const tc = tracingState.current;
      let traceIds: UniTrackTraceIds | undefined;
      let nextInit = init;
      if (tc.enabled && shouldInjectTrace(hostOf(input), tc.allowlistHosts)) {
        const headers = new Headers(init?.headers);
        if (!headers.has(tc.headerName)) {
          traceIds = newTrace();
          headers.set(tc.headerName, traceparentHeader(traceIds, tc.sampled));
          nextInit = { ...(init ?? {}), headers };
        }
      }

      try {
        const res = await orig(input, nextInit);
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
          // Carry trace ids on the event so the portal can offer a "copy
          // trace_id → grep backend logs" affordance per request.
          ...(traceIds ? { trace_id: traceIds.traceId, span_id: traceIds.spanId } : {}),
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

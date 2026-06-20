// @unitrack/react-native
//
// Public API. Calls the native module which forwards to the iOS / Android
// SDK installed underneath. Auto-capture (screens, taps, network) is
// configured on the native side; React Navigation hooks add JS-level
// screen tracking on top.

import { NativeModules, Platform, NativeEventEmitter, type EmitterSubscription } from 'react-native';
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

  // Session API parity (added with the offline + session APIs in 1.1).
  currentSessionId(): Promise<string>;
  sessionIndex(): Promise<number>;
  previousSessionId(): Promise<string>;
  rotateSession(): Promise<void>;

  // Offline queue introspection + flush callback toggle.
  pendingEventCounts(): Promise<Record<string, number>>;
  setFlushCallbackEnabled(enabled: boolean): Promise<void>;

  // Application context + typed remote-config resolver.
  applicationContext(): Promise<Record<string, unknown>>;
  getRemoteValue(key: string, type: 'string' | 'bool' | 'int' | 'long' | 'double'): Promise<unknown>;

  // Session-stat sidebag.
  sessionScreenCount(): Promise<number>;
  sessionHadError(): Promise<boolean>;
  sessionHadCrash(): Promise<boolean>;
  incrementScreenCount(): Promise<void>;
  markSessionError(): Promise<void>;
  markSessionCrash(): Promise<void>;
  resetSessionStats(): Promise<void>;

  // Provider Adapters (Phase 6).
  attachFirebaseAdapter(): Promise<boolean>;
  pendingProviderRetryCount(): Promise<number>;
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

  // Convention layer — portal `snowplow.event_names` maps a 6-kind taxonomy
  // (click / result / screen_view / crash / api / session) onto the wire
  // event names. setEventNames() is typically called from
  // UniTrackRemoteConfig.applyConventions(cfg) so the SDK is in sync with
  // the portal without an app rebuild.
  private eventNames: Record<string, string> = {};
  setEventNames(map: Record<string, string>) {
    this.eventNames = { ...map };
  }

  private resolveKind(name: string): string {
    const v = this.eventNames[name];
    return (v && v.length > 0) ? v : name;
  }

  // Map a raw auto-capture event ("click", "screen_load_completed", …) to its
  // convention kind. Returns null when the event isn't recognised — those go
  // out under their own name (legacy behaviour). Matches the Flutter Snowplow
  // provider's _kindForRawEvent so cross-platform shapes stay aligned.
  private kindForRawEvent(raw: string): string | null {
    switch (raw) {
      case 'click': return 'click';
      case 'screen_load_completed':
      case 'screen_viewed':
      case 'screen_exited':
      case 'screen_view': return 'screen_view';
      case 'crash':
      case 'application_error': return 'crash';
      case 'network_request': return 'api';
      case 'session_started':
      case 'session_ended': return 'session';
    }
    return null;
  }

  track(event: string, properties: EventProperties = {}) {
    let name = event;
    let props: EventProperties = properties;
    // If the caller passed a convention kind directly (or an auto-capture
    // event maps to one), resolve to the portal-configured wire name AND
    // stamp the business signal as `event_name` in the payload so a single
    // iglu schema carries both the generic shape and the specific business.
    const kind = this.eventNames[event] ? event : this.kindForRawEvent(event);
    if (kind && this.eventNames[kind]) {
      name = this.eventNames[kind];
      // Caller may already have populated event_name — don't clobber it.
      const business = (properties as any).event_name ?? event;
      props = { event_name: business, ...properties };
    }
    this.forEachProvider((p) => p.track(name, props));
    return native.track(name, JSON.stringify(props));
  }

  setScreen(name: string) {
    this.forEachProvider((p) => p.setScreen(name));
    return native.setScreen(name);
  }
  flush()                 { return native.flush(); }
  setEnabled(e: boolean)  { return native.setEnabled(e); }

  // ─── Session API parity (iOS / Android / Flutter) ──────────────────────
  //
  // The native core owns session_id rotation + persists session_index across
  // launches via session.json. Apps call these instead of keeping their own
  // (resetting-on-cold-start) counter.

  /** UUID of the active session — empty before init. */
  currentSessionId(): Promise<string>  { return native.currentSessionId(); }

  /** Lifetime session counter (persists across launches). 1 on first
   *  install, +1 per timeout-driven rotation. */
  sessionIndex(): Promise<number>      { return native.sessionIndex(); }

  /** UUID of the session that just closed; empty on the first session after
   *  install. Pair with [currentSessionId] when emitting session_started. */
  previousSessionId(): Promise<string> { return native.previousSessionId(); }

  /** Force a session rotation now. Bumps sessionIndex, mints a new UUID,
   *  records the just-closed UUID as previousSessionId. Use on logout /
   *  switch-account / new-context boundaries when the inactivity timeout
   *  isn't enough. */
  rotateSession(): Promise<void>       { return native.rotateSession(); }

  // ─── Offline queue introspection ───────────────────────────────────────

  /** Snapshot of events still sitting in the SQLite offline queue, grouped
   *  by raw event_name. Used by debug toasts during airplane-mode testing:
   *  `Saved 7 ev_screen_view, 3 ev_click`. Empty before init or queue empty. */
  pendingEventCounts(): Promise<Record<string, number>> {
    return native.pendingEventCounts();
  }

  // Lazy EventEmitter — created on the first onFlushCompleted subscription
  // so apps that never use it pay no setup cost.
  private flushEmitter: NativeEventEmitter | null = null;
  private flushSubscribers = 0;

  /** Fires after each successful batch upload with the per-event_name
   *  breakdown of THAT batch (vd `{ev_click: 3, ev_result: 2}`). Returns
   *  an [EmitterSubscription]; call `.remove()` when you're done so the
   *  native worker stops posting if no other listener remains. */
  onFlushCompleted(
    handler: (counts: Record<string, number>) => void,
  ): EmitterSubscription {
    if (!this.flushEmitter) {
      this.flushEmitter = new NativeEventEmitter(NativeModules.UniTrack);
    }
    if (this.flushSubscribers === 0) {
      native.setFlushCallbackEnabled(true).catch(() => {});
    }
    this.flushSubscribers += 1;
    const sub = this.flushEmitter.addListener('onFlushCompleted', (e: { counts?: Record<string, number> }) => {
      handler(e?.counts ?? {});
    });
    // Wrap .remove() so we can toggle the native flag off when the last
    // subscriber goes away.
    const origRemove = sub.remove.bind(sub);
    sub.remove = () => {
      origRemove();
      this.flushSubscribers = Math.max(0, this.flushSubscribers - 1);
      if (this.flushSubscribers === 0) {
        native.setFlushCallbackEnabled(false).catch(() => {});
      }
    };
    return sub;
  }

  // ─── Application context + remote values ───────────────────────────────

  /** Device/app metadata bag captured at init (platform, app_version,
   *  network_*, device_*). Same dict the native Snowplow provider uses to
   *  build its `application_context` entity. Empty before init. */
  applicationContext(): Promise<Record<string, unknown>> {
    return native.applicationContext();
  }

  /** Resolve a runtime value. Resolution order:
   *    1. Portal `sdk_config.custom_values[key]`
   *    2. Any registered remote-value provider (Firebase RC)
   *    3. [defaultValue]
   *
   *  T may be `string | number | boolean`. Coercion happens on the native
   *  side based on the type of [defaultValue]. */
  async getRemoteValue<T extends string | number | boolean>(
    key: string,
    defaultValue: T,
  ): Promise<T> {
    let hint: 'string' | 'bool' | 'int' | 'double';
    if (typeof defaultValue === 'boolean') hint = 'bool';
    else if (typeof defaultValue === 'number') {
      hint = Number.isInteger(defaultValue) ? 'int' : 'double';
    } else hint = 'string';
    try {
      const raw = await native.getRemoteValue(key, hint);
      if (raw == null) return defaultValue;
      return raw as T;
    } catch {
      return defaultValue;
    }
  }

  // ─── Session-stat sidebag ──────────────────────────────────────────────

  sessionScreenCount(): Promise<number>  { return native.sessionScreenCount(); }
  sessionHadError(): Promise<boolean>    { return native.sessionHadError(); }
  sessionHadCrash(): Promise<boolean>    { return native.sessionHadCrash(); }
  incrementScreenCount(): Promise<void>  { return native.incrementScreenCount(); }
  markSessionError(): Promise<void>      { return native.markSessionError(); }
  markSessionCrash(): Promise<void>      { return native.markSessionCrash(); }
  resetSessionStats(): Promise<void>     { return native.resetSessionStats(); }

  // ─── Provider Adapters (Phase 6) ───────────────────────────────────────
  //
  // Add HTTP backends (Kibana / ELK / FPT internal) or attach Firebase
  // Analytics via reflection. UniTrack has 0 import on Firebase; the adapter
  // is a runtime auto-detect via NSClassFromString / Class.forName.

  /**
   * Attach the Firebase Adapter. Resolves to true if Firebase Analytics was
   * found at runtime and the adapter is now active. False means the host
   * hasn't linked Firebase — call again after they do, no rebuild needed.
   */
  attachFirebaseAdapter(): Promise<boolean> {
    return native.attachFirebaseAdapter();
  }

  /** Snapshot of events waiting in the per-provider ack queue. Demo/debug. */
  pendingProviderRetryCount(): Promise<number> {
    return native.pendingProviderRetryCount();
  }

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

/**
 * Auto-capture outgoing URL opens via Linking.openURL — every time the app
 * launches Safari / Maps / Zalo / Telegram / a custom-scheme app, we emit
 * `third_party_open` BEFORE handing the URL to the OS. Classification
 * matches the iOS swizzler + Android helper (browser / phone / mail / sms /
 * <scheme>). Wraps once; subsequent calls are no-ops.
 */
export function installThirdPartyOpenAutoCapture() {
  const { Linking } = require('react-native');
  if (!Linking || !Linking.openURL) return;
  if ((Linking.openURL as any).__unitrack_wrapped) return;
  const orig = Linking.openURL.bind(Linking);
  const wrapped = (url: string) => {
    try {
      let scheme = '';
      try { scheme = (new URL(url).protocol || '').replace(/:$/, '').toLowerCase(); }
      catch (_) { /* malformed — fall through */ }
      const target = scheme === 'http' || scheme === 'https' ? 'browser'
        : scheme === 'tel'    ? 'phone'
        : scheme === 'mailto' ? 'mail'
        : scheme === 'sms'    ? 'sms'
        : (scheme || 'unknown');
      UniTrack.track('third_party_open', {
        target, url, ...(scheme ? { scheme } : {}),
      });
    } catch (_) { /* never block the launch */ }
    return orig(url);
  };
  (wrapped as any).__unitrack_wrapped = true;
  Linking.openURL = wrapped;
}

export default UniTrack;
export { UniTrackTapBoundary } from './autoTap';
export { tapState } from './tapState';
export { default as createNavigationTracker } from './navigation';
export { default as safeJsonParse } from './safeJsonParse';

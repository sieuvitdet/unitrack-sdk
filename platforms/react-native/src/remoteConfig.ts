// UniTrackRemoteConfig — fetches the app's tracking config from the portal at
// startup (GET {portal}/config, auth = api_key), so endpoints, providers,
// schemas and event-rewrite rules can change WITHOUT rebuilding the app.
//
// Resilient: on success caches in-memory (the app may persist via AsyncStorage);
// on failure/timeout returns the last value or a built-in default. Uses RN's
// global fetch — no extra dependency.

import UniTrack, { type EventProperties, type EventRule } from './index';

export interface RemoteConfigRule {
  match_event: string;
  match_screen?: string;
  match_element_key?: string;
  to_name: string;
  add_props?: EventProperties;
}

export interface RemoteConfigTracing {
  enabled?: boolean;
  header_name?: string;
  allowlist_hosts?: string[];
  sampled?: boolean;
}

export interface RemoteConfigData {
  version: number;
  endpoint: string;
  sdk_config?: Record<string, unknown>;
  snowplow?: Record<string, unknown>;
  firebase?: Record<string, unknown>;
  event_registry?: unknown[];
  rules?: RemoteConfigRule[];
  /** W3C distributed-tracing block — apply via applyTracing(). */
  tracing?: RemoteConfigTracing;
}

const cache: Record<string, RemoteConfigData> = {};

function builtinDefault(): RemoteConfigData {
  return {
    version: 0,
    endpoint: 'https://mobix.asia/event-tracking-mobile/v1/events',
    sdk_config: { batchSize: 10, flushIntervalMs: 3000, autoCapture: true,
                  trackScreens: true, trackTaps: true, trackNetwork: true },
    snowplow: { enabled: false },
    firebase: { enabled: false },
    event_registry: [],
    rules: [],
  };
}

export const UniTrackRemoteConfig = {
  /** Apply the tracing block (if present) to UniTrack so the fetch
   *  interceptor picks it up. No-op when the portal didn't send `tracing`. */
  applyTracing(cfg: RemoteConfigData): void {
    const t = cfg.tracing;
    if (!t) return;
    UniTrack.setTracing({
      enabled: t.enabled === true,
      headerName: t.header_name ?? 'traceparent',
      allowlistHosts: t.allowlist_hosts ?? [],
      sampled: t.sampled !== false,
    });
  },

  /** Map config rules → SDK EventRule[]. */
  toEventRules(cfg: RemoteConfigData): EventRule[] {
    return (cfg.rules ?? []).map((r) => ({
      matchEvent: r.match_event,
      matchScreen: r.match_screen,
      matchElementKey: r.match_element_key,
      toName: r.to_name,
      addProps: r.add_props ?? {},
    }));
  },

  /** Fetch config from the portal. Always resolves with a usable config
   *  (fresh, cached, or fallback/default). Never throws. */
  async fetch(
    apiKey: string,
    configURL: string,
    timeoutMs = 3000,
    fallback?: RemoteConfigData,
  ): Promise<RemoteConfigData> {
    try {
      const controller = new AbortController();
      const t = setTimeout(() => controller.abort(), timeoutMs);
      const resp = await fetch(configURL, {
        method: 'GET',
        headers: { Authorization: `Bearer ${apiKey}` },
        signal: controller.signal,
      });
      clearTimeout(t);
      if (resp.ok) {
        const cfg = (await resp.json()) as RemoteConfigData;
        cache[apiKey] = cfg;
        return cfg;
      }
    } catch (e) {
      console.warn('[UniTrack] RemoteConfig fetch failed', e);
    }
    return cache[apiKey] ?? fallback ?? builtinDefault();
  },
};

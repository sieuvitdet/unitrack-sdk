// UniTrackRemoteConfig — fetches the app's tracking config from the portal at
// startup (GET {portal}/config, auth = api_key), so endpoints, providers,
// schemas and event-rewrite rules can change WITHOUT rebuilding the app.
//
// Resilient: on success caches in-memory (the app may persist via AsyncStorage);
// on failure/timeout returns the last value or a built-in default. Uses RN's
// global fetch — no extra dependency.

import UniTrack from './index';

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

  /** Fetch config from the portal. Always resolves with a usable config
   *  (fresh, cached, or fallback/default). Never throws.
   *
   *  `flavor` selects a per-build override block (dev / staging / beta /
   *  production). Apps usually wire this from their build flavor — for RN
   *  use `__DEV__` or expose your bundler's env variable. */
  async fetch(
    apiKey: string,
    configURL: string,
    flavor?: string,
    timeoutMs = 3000,
    fallback?: RemoteConfigData,
  ): Promise<RemoteConfigData> {
    // Append ?flavor=... to the URL. URL constructor handles existing query
    // strings cleanly; fall back to string concat if URL isn't available
    // (very old RN runtimes).
    let url = configURL;
    if (flavor) {
      try {
        const u = new URL(configURL);
        u.searchParams.set('flavor', flavor);
        url = u.toString();
      } catch (_) {
        url = configURL + (configURL.includes('?') ? '&' : '?') +
              'flavor=' + encodeURIComponent(flavor);
      }
    }
    try {
      const controller = new AbortController();
      const t = setTimeout(() => controller.abort(), timeoutMs);
      const headers: Record<string, string> = { Authorization: `Bearer ${apiKey}` };
      if (flavor) headers['X-UniTrack-Flavor'] = flavor;
      const resp = await fetch(url, { method: 'GET', headers, signal: controller.signal });
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

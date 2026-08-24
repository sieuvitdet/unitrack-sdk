// Frozen-config mode (giống FPT Life): load JSON từ static URL hoặc inline
// object → apply UniTrackConfig + Snowplow provider config. KHÔNG fetch
// portal. SSE poll optional cho app muốn realtime refresh.
//
// Port logic từ Flutter `src/remote_config.dart` + Android
// `UniTrackRemoteConfig.kt` — schema giống trackingConfig.json.

import type { UniTrackConfig } from './types';

export interface RemoteConfig {
  /** API key. Nằm luôn trong file config, host không phải truyền tay. */
  apiKey?: string;
  endpoint?: string;
  pii_salt?: string;
  sdk_config?: {
    batchSize?: number;
    flushIntervalMs?: number;
    logLevel?: 'debug' | 'info' | 'warn' | 'error';
    autoCapture?: boolean;
    trackScreens?: boolean;
    trackTaps?: boolean;
    trackNetwork?: boolean;
    screen_start_event?: string;
    screen_end_event?: string;
    screen_load_event?: string;
    sampling_rate?: number;
    require_consent?: boolean;
  };
  snowplow?: {
    enabled?: boolean;
    endpoint?: string;
    appId?: string;
    iglu_vendor?: string;
    default_version?: string;
    event_names?: Record<string, string>;
    drop_events?: string[];
    /** Override riêng từng nền. Native dùng `ios`/`android`, web dùng `web`. */
    web?: { endpoint?: string; appId?: string };
  };
  tracing?: {
    enabled?: boolean;
    header_name?: string;
    allowlist_hosts?: string[];
    sampled?: boolean;
  };
  flavors?: Record<string, Partial<RemoteConfig>>;
  [k: string]: unknown;
}

/** Fetch JSON config từ URL. App có thể truyền URL static (vd
 * /tracking_config.json) hoặc nội bộ. */
export async function fetchRemoteConfig(url: string, timeoutMs = 3000): Promise<RemoteConfig | null> {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), timeoutMs);
    const res = await fetch(url, { signal: ctl.signal });
    clearTimeout(t);
    if (!res.ok) return null;
    return (await res.json()) as RemoteConfig;
  } catch {
    return null;
  }
}

/** Apply flavor override sâu — deep merge. Phù hợp với schema FPT Life. */
export function applyFlavor(cfg: RemoteConfig, flavor: string): RemoteConfig {
  const override = cfg.flavors?.[flavor];
  if (!override) return cfg;
  return deepMerge(cfg, override as Record<string, unknown>) as RemoteConfig;
}

function deepMerge(a: Record<string, unknown>, b: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...a };
  for (const k of Object.keys(b)) {
    const va = a[k];
    const vb = b[k];
    if (
      vb !== null && typeof vb === 'object' && !Array.isArray(vb) &&
      va !== null && typeof va === 'object' && !Array.isArray(va)
    ) {
      out[k] = deepMerge(va as Record<string, unknown>, vb as Record<string, unknown>);
    } else {
      out[k] = vb;
    }
  }
  return out;
}

/** Endpoint/appId Snowplow sau khi tính override theo nền.
 *
 * Parity `UniTrackRemoteConfig.resolvedEndpoint` bên iOS: khối `snowplow.web`
 * đè lên giá trị chung, giống cách `snowplow.ios` đè bên native. */
export function resolveSnowplow(cfg: RemoteConfig): { endpoint?: string; appId?: string } {
  const sp = cfg.snowplow;
  return {
    endpoint: sp?.web?.endpoint || sp?.endpoint,
    appId:    sp?.web?.appId    || sp?.appId,
  };
}

/** Map RemoteConfig → UniTrackConfig — extract subset fields cho SDK init. */
export function toSDKConfig(cfg: RemoteConfig): UniTrackConfig {
  const s = cfg.sdk_config || {};
  return {
    endpoint: cfg.endpoint || '',
    piiSalt: cfg.pii_salt,
    batchSize: s.batchSize,
    flushIntervalMs: s.flushIntervalMs,
    autoCapture: s.autoCapture,
    trackScreens: s.trackScreens,
    trackTaps: s.trackTaps,
    trackNetwork: s.trackNetwork,
    screenStartEvent: s.screen_start_event,
    screenEndEvent: s.screen_end_event,
    screenLoadEvent: s.screen_load_event,
    samplingRate: s.sampling_rate,
    requireConsent: s.require_consent,
    tracingAllowlistHosts: cfg.tracing?.enabled ? (cfg.tracing.allowlist_hosts || []) : [],
  };
}

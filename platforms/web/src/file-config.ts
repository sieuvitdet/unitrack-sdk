/** Nạp config từ file JSON tĩnh — parity với FSDKTracking của FPT Life.
 *
 * iOS/Android fetch config này từ server rồi map sang `UniTrack.Config`
 * (`FSDKTracking+Bootstrap.swift:initializeCore`, `FSDKTrackingConfig.kt`).
 * Web dùng CÙNG schema nhưng đọc từ file tĩnh: mọi thông tin nằm sẵn trong
 * file, không phải gọi API lấy động.
 *
 * Giữ nguyên tên field của native (`sdkConfig`, `snowplow.iglu_vendor`, …) để
 * một file config dùng chung được cho cả ba nền — đổi tên cho "hợp JS" sẽ phá
 * mất điều đó.
 */
import type { UniTrackConfig } from './types';

/** Schema file config. Bám `UniTrackRemoteConfig` (iOS
 * `UniTrackRemoteConfig.swift:23`); chỉ giữ phần web dùng được — bỏ
 * `firebase` (SDK riêng) và `httpProviders` (web gắn tay qua addProvider). */
export interface UniTrackFileConfig {
  version?: number;
  /** API key. Nằm trong file luôn, không truyền qua tham số. */
  apiKey?: string;
  /** Core HTTP ingest. Rỗng → chỉ fan-out Snowplow (giống FPT Life). */
  endpoint?: string;

  sdkConfig?: {
    batchSize?: number;
    flushIntervalMs?: number;
    samplingRate?: number;
    autoCapture?: boolean;
    trackScreens?: boolean;
    trackTaps?: boolean;
    trackNetwork?: boolean;
    trackLifecycle?: boolean;
    sessionTimeoutMs?: number;
    screenStartEvent?: string;
    screenEndEvent?: string;
    screenLoadEvent?: string;
    requireConsent?: boolean;
    anonymousTracking?: 'session' | 'full';
    piiSalt?: string;
    verboseLogging?: boolean;
  };

  snowplow?: {
    enabled?: boolean;
    endpoint?: string;
    appId?: string;
    iglu_vendor?: string;
    default_version?: string;
    event_names?: Record<string, string>;
    drop_events?: string[];
  };

  tracing?: {
    enabled?: boolean;
    allowlistHosts?: string[];
  };
}

/** Map file config → UniTrackConfig của web.
 *
 * Chỉ set field khi file có khai báo: `undefined` để `defaultCfg()` giữ mặc
 * định, còn gán bừa `?? default` ở đây sẽ nhân đôi chỗ định nghĩa mặc định.
 */
export function toUniTrackConfig(file: UniTrackFileConfig): UniTrackConfig {
  const s = file.sdkConfig || {};
  const cfg: UniTrackConfig = {};

  if (file.endpoint != null) cfg.endpoint = file.endpoint;

  // Chép thẳng những field trùng tên hệt nhau giữa file và UniTrackConfig.
  const same = [
    'batchSize', 'flushIntervalMs', 'samplingRate', 'autoCapture',
    'trackScreens', 'trackTaps', 'trackNetwork', 'trackLifecycle',
    'sessionTimeoutMs', 'screenStartEvent', 'screenEndEvent',
    'screenLoadEvent', 'requireConsent', 'anonymousTracking', 'piiSalt',
    'verboseLogging',
  ] as const;
  for (const k of same) {
    if (s[k] != null) (cfg as Record<string, unknown>)[k] = s[k];
  }

  // tracing.allowlistHosts chỉ có tác dụng khi enabled — tắt mà vẫn nhét
  // allowlist vào sẽ inject traceparent ngoài ý muốn.
  if (file.tracing?.enabled && file.tracing.allowlistHosts) {
    cfg.tracingAllowlistHosts = file.tracing.allowlistHosts;
  }

  return cfg;
}

/** Tải file config JSON.
 *
 * `cache: 'no-cache'` để đổi config trên server là lần tải trang sau ăn ngay,
 * không phải chờ cache hết hạn.
 */
export async function loadFileConfig(url: string): Promise<UniTrackFileConfig> {
  const res = await fetch(url, { cache: 'no-cache' });
  if (!res.ok) throw new Error(`config HTTP ${res.status}`);
  return res.json();
}

// Lightweight Snowplow provider — gửi self-describing event tới collector
// qua `/com.snowplowanalytics.snowplow/tp2` endpoint. Không depend
// `@snowplow/browser-tracker` để giảm bundle size — chỉ 1 fetch POST đơn
// giản.
//
// Port pattern từ Flutter `unitrack_snowplow` + iOS SnowplowProvider:
// - kind mapping (click → ev_click, screen_viewed → ev_screen,…)
// - Iglu schema URI build: iglu:<vendor>/<name>/jsonschema/<ver>
// - Self-describing JSON event với entity user_context + application_context

import type { AnalyticsProvider, EventName, EventProperties } from '../types';

export interface SnowplowProviderConfig {
  endpoint: string;                       // vd https://ftracking.fpt.vn
  appId: string;
  igluVendor: string;                     // vd vn.fpt.ftel.snowplow
  defaultVersion?: string;                // default '1-0-0'
  /** Map raw event name → Snowplow schema name. Default: identity. */
  eventNames?: Record<string, string>;
  /** Stamp các entity context vào mọi event. */
  userContext?: EventProperties;
  base64Encoding?: boolean;
}

export class SnowplowProvider implements AnalyticsProvider {
  readonly name = 'SnowplowProvider';
  private buffer: any[] = [];
  private flushTimer: ReturnType<typeof setInterval> | null = null;
  private userId: string | null = null;
  private userTraits: EventProperties = {};

  constructor(private cfg: SnowplowProviderConfig) {}

  init(): void {
    Object.assign(this.userTraits, this.cfg.userContext || {});
    this.flushTimer = setInterval(() => this.flush(), 3000);
    window.addEventListener('pagehide', () => this.flushBeacon());
    window.addEventListener('online', () => this.flush());
  }

  setUser(userId: string | null, traits: EventProperties): void {
    this.userId = userId;
    this.userTraits = { ...(traits || {}) };
  }

  track(name: EventName, props: EventProperties): void {
    const kind = this.cfg.eventNames?.[name] ?? this.mapKind(name);
    const schemaName = this.cfg.eventNames?.[kind] ?? kind;
    const schema = `iglu:${this.cfg.igluVendor}/${schemaName}/jsonschema/${this.cfg.defaultVersion || '1-0-0'}`;

    const enriched: EventProperties = { ...props };
    if (enriched.event_action == null) enriched.event_action = name;

    const ue_pr = {
      schema: 'iglu:com.snowplowanalytics.snowplow/unstruct_event/jsonschema/1-0-0',
      data: { schema, data: enriched },
    };

    const contexts: any[] = [];
    if (this.userId) {
      contexts.push({
        schema: `iglu:${this.cfg.igluVendor}/user_context/jsonschema/1-0-0`,
        data: { user_id: this.userId, ...this.userTraits },
      });
    }
    contexts.push({
      schema: `iglu:${this.cfg.igluVendor}/application_context/jsonschema/1-0-0`,
      data: {
        app_id: this.cfg.appId,
        platform: 'web',
        user_agent: navigator.userAgent,
        screen_resolution: `${screen.width}x${screen.height}`,
        viewport: `${window.innerWidth}x${window.innerHeight}`,
        language: navigator.language,
        referrer: document.referrer,
      },
    });

    const co = {
      schema: 'iglu:com.snowplowanalytics.snowplow/contexts/jsonschema/1-0-1',
      data: contexts,
    };

    const payload: Record<string, string> = {
      e: 'ue',                            // unstruct event
      eid: this.uuid(),
      dtm: String(Date.now()),
      tv: 'js-unitrack-0.1',
      p: 'web',
      aid: this.cfg.appId,
      tna: 'unitrack',
      url: window.location.href,
      page: document.title,
      ue_pr: JSON.stringify(ue_pr),
      co: JSON.stringify(co),
    };

    this.buffer.push(payload);
    if (this.buffer.length >= 10) this.flush();
  }

  private mapKind(name: string): string {
    switch (name) {
      case 'click':
      case 'tap':
        return 'click';
      case 'screen_viewed':
      case 'screen_exited':
      case 'screen_load_completed':
      case 'screen_view':
        return 'screen_view';
      case 'network_request':
      case 'network_error':
        return 'api';
      case 'crash':
        return 'crash';
      default:
        return name;
    }
  }

  async flush(): Promise<void> {
    if (!this.buffer.length || !navigator.onLine) return;
    const batch = this.buffer.splice(0, this.buffer.length);
    try {
      await fetch(`${this.cfg.endpoint}/com.snowplowanalytics.snowplow/tp2`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          schema: 'iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4',
          data: batch,
        }),
      });
    } catch {
      // Retry: đẩy lại buffer.
      this.buffer.unshift(...batch);
    }
  }

  flushBeacon(): void {
    if (!this.buffer.length) return;
    if (typeof navigator.sendBeacon !== 'function') return;
    const batch = this.buffer.splice(0, this.buffer.length);
    try {
      const body = JSON.stringify({
        schema: 'iglu:com.snowplowanalytics.snowplow/payload_data/jsonschema/1-0-4',
        data: batch,
      });
      navigator.sendBeacon(
        `${this.cfg.endpoint}/com.snowplowanalytics.snowplow/tp2`,
        new Blob([body], { type: 'application/json' }),
      );
    } catch {
      this.buffer.unshift(...batch);
    }
  }

  private uuid(): string {
    if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
      return crypto.randomUUID();
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  destroy(): void {
    if (this.flushTimer) clearInterval(this.flushTimer);
  }
}

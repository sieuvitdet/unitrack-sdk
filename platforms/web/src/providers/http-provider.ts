// HTTP provider — POST batch event tới custom endpoint (Kibana/ELK/portal
// nội bộ). Đường ingest mặc định của UniTrack web.

import type { AnalyticsProvider, EventName, EventProperties, QueuedEvent } from '../types';
import * as Queue from '../offline-queue';

export interface HttpProviderConfig {
  endpoint: string;
  apiKey?: string;
  /** Field path để serialize batch — vd 'data' → POST { data: [...] }. */
  bodyField?: string;
  /** Headers thêm vào mỗi request. */
  headers?: Record<string, string>;
  /** Max event per POST. */
  batchSize?: number;
  /** Flush interval ms khi queue chưa đầy batch. */
  flushIntervalMs?: number;
}

/** Row shape portal `ingest.js` chờ. `isValid()` reject nếu thiếu event_id /
 * event_name / timestamp, và reject im lặng (vẫn trả HTTP 200) nên sai format
 * rất khó thấy. Flat, không bọc {name, props}. */
interface PendingEvent {
  event_id: string;
  event_name: string;
  timestamp: number;
  session_id?: unknown;
  screen?: unknown;
  user_id?: unknown;
  element_key?: unknown;
  platform: string;
  properties: EventProperties;
  device: Record<string, unknown>;
}

function newEventId(): string {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return `web-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

function deviceInfo(): Record<string, unknown> {
  const nav = globalThis.navigator;
  return {
    platform: 'web',
    os: nav?.platform || 'unknown',
    user_agent: nav?.userAgent || '',
    language: nav?.language || '',
    screen_w: globalThis.screen?.width,
    screen_h: globalThis.screen?.height,
  };
}

export class HttpProvider implements AnalyticsProvider {
  readonly name = 'HttpProvider';
  private buffer: PendingEvent[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** Số lần gửi hỏng liên tiếp — dùng để giãn khoảng cách retry. */
  private failStreak = 0;
  /** Đang có request bay → không mở request thứ hai. */
  private inFlight = false;

  constructor(private cfg: HttpProviderConfig) {}

  init(): void {
    this.scheduleNext();
    // Rời page — bắn nốt buffer RAM bằng beacon, phần không kịp thì cất xuống
    // IndexedDB để lần mở sau gửi tiếp.
    window.addEventListener('pagehide', () => this.flushBeacon());
    window.addEventListener('online', () => { void this.drainPersisted(); });
    // Mở lại tab/app → gửi ngay những gì còn tồn từ phiên trước, không đợi
    // sự kiện `online` (nếu mạng vẫn tốt thì sự kiện đó chẳng bao giờ bắn).
    void this.drainPersisted();
  }

  track(name: EventName, props: EventProperties): void {
    this.buffer.push({
      event_id:    newEventId(),
      event_name:  name,
      // `ts` do core stamp lúc track(); fallback now nếu event tới từ đường khác.
      timestamp:   Number(props.ts) || Date.now(),
      session_id:  props.session_id,
      screen:      props.screen,
      user_id:     props.user_id,
      element_key: props.element_key,
      platform:    'web',
      properties:  props,
      device:      deviceInfo(),
    });
    if (this.buffer.length >= (this.cfg.batchSize ?? 10)) {
      this.flush();
    }
  }

  async flush(): Promise<void> {
    if (!this.cfg.endpoint) return;
    // Mất mạng → dồn thẳng xuống IndexedDB, đừng giữ trong RAM chờ có mạng:
    // tab đóng lúc đang offline là mất trắng.
    if (!navigator.onLine) {
      await this.persist(this.buffer.splice(0, this.buffer.length));
      return;
    }
    if (this.inFlight) return;            // tránh 2 flush chồng nhau khi retry
    if (!this.buffer.length) return;

    this.inFlight = true;
    const batch = this.buffer.splice(0, this.buffer.length);
    const body = this.cfg.bodyField ? { [this.cfg.bodyField]: batch } : batch;
    try {
      const res = await fetch(this.cfg.endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(this.cfg.apiKey ? { Authorization: `Bearer ${this.cfg.apiKey}` } : {}),
          ...(this.cfg.headers || {}),
        },
        body: JSON.stringify(body),
      });
      // 5xx là lỗi tạm của server → giữ lại để gửi sau. 4xx thì gửi lại cũng
      // hỏng y hệt (sai key, payload xấu) nên bỏ, tránh kẹt queue vĩnh viễn.
      if (res.status >= 500) throw new Error(`HTTP ${res.status}`);
      this.failStreak = 0;
    } catch {
      this.failStreak++;
      await this.persist(batch);
    } finally {
      this.inFlight = false;
    }
  }

  /** Cất batch xuống IndexedDB thay vì giữ trong RAM. */
  private async persist(batch: PendingEvent[]): Promise<void> {
    if (!batch.length) return;
    await Queue.enqueueBatch(batch as unknown as QueuedEvent[]);
  }

  /** Gửi lại những gì đang nằm trong IndexedDB. Thành công thì xoá khỏi queue;
   * hỏng thì giữ nguyên để lượt sau thử tiếp. */
  private async drainPersisted(): Promise<void> {
    if (!navigator.onLine || this.inFlight || !this.cfg.endpoint) return;
    const rows = await Queue.drain();
    if (!rows.length) return;

    this.inFlight = true;
    try {
      for (let i = 0; i < rows.length; i += this.batchSize()) {
        const slice = rows.slice(i, i + this.batchSize());
        const ids = slice.map((r) => r.id).filter((x): x is number => typeof x === 'number');
        // `id` là khoá của IndexedDB, không phải dữ liệu event → bỏ trước khi gửi.
        const payload = slice.map(({ id: _id, ...rest }) => rest);
        const body = this.cfg.bodyField ? { [this.cfg.bodyField]: payload } : payload;
        const res = await fetch(this.cfg.endpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(this.cfg.apiKey ? { Authorization: `Bearer ${this.cfg.apiKey}` } : {}),
            ...(this.cfg.headers || {}),
          },
          body: JSON.stringify(body),
        });
        if (res.status >= 500) throw new Error(`HTTP ${res.status}`);
        await Queue.removeIds(ids);       // 4xx cũng xoá — gửi lại vẫn hỏng
      }
      this.failStreak = 0;
    } catch {
      this.failStreak++;                  // giữ nguyên phần chưa xoá, lượt sau thử lại
    } finally {
      this.inFlight = false;
    }
  }

  private batchSize(): number {
    return this.cfg.batchSize ?? 10;
  }

  /** Khoảng cách tới lượt gửi kế tiếp — giãn gấp đôi sau mỗi lần hỏng liên
   * tiếp, trần 60s. Không có nó thì endpoint sập sẽ bị mọi client dội đều
   * đặn mỗi 2 giây, đúng lúc nó yếu nhất. */
  private nextDelay(): number {
    const base = this.cfg.flushIntervalMs ?? 3000;
    if (this.failStreak === 0) return base;
    return Math.min(base * 2 ** Math.min(this.failStreak, 5), 60_000);
  }

  private scheduleNext(): void {
    this.timer = setTimeout(async () => {
      await this.flush();
      await this.drainPersisted();
      this.scheduleNext();
    }, this.nextDelay());
  }

  /** sendBeacon đảm bảo gửi được kể cả khi page đang unload. */
  flushBeacon(): void {
    if (!this.buffer.length || !this.cfg.endpoint) return;
    if (typeof navigator.sendBeacon !== 'function') return;
    const batch = this.buffer.splice(0, this.buffer.length);
    const body = this.cfg.bodyField
      ? { [this.cfg.bodyField]: batch }
      : batch;
    // sendBeacon không set được header → Bearer mất. Portal handleIngest có
    // fallback đọc `?api_key=`, dùng nhánh đó cho beacon.
    let url = this.cfg.endpoint;
    if (this.cfg.apiKey) {
      url += (url.includes('?') ? '&' : '?') + 'api_key=' + encodeURIComponent(this.cfg.apiKey);
    }
    // sendBeacon trả false khi payload quá lớn hoặc bị chặn. Page sắp đóng nên
    // đẩy về buffer RAM là mất trắng — cất xuống IndexedDB mới giữ được.
    let sent = false;
    try {
      sent = navigator.sendBeacon(
        url, new Blob([JSON.stringify(body)], { type: 'application/json' }));
    } catch { sent = false; }
    if (!sent) void this.persist(batch);
  }

  destroy(): void {
    if (this.timer) clearTimeout(this.timer);
  }
}

// Google Analytics 4 — fan-out qua gtag.js.
//
// GA4 có sẵn trên phần lớn site rồi, nên provider này KHÔNG tự nạp gtag: nếu
// nạp thêm sẽ có hai instance đá nhau. Chỉ đẩy event vào `window.dataLayer`
// mà gtag của trang đang đọc.
//
// Ràng buộc của GA4 phải tôn trọng, nếu không event bị bỏ im lặng:
//   - tên event: chỉ [a-z0-9_], tối đa 40 ký tự, phải bắt đầu bằng chữ
//   - tên tham số: tối đa 40 ký tự; giá trị chuỗi tối đa 100 ký tự
//   - tối đa 25 tham số mỗi event

import type { AnalyticsProvider, EventName, EventProperties } from '../types';

export interface GA4ProviderConfig {
  /** Measurement ID (G-XXXXXXX). Chỉ dùng để log — gtag phải do trang tự nạp. */
  measurementId?: string;
  /** Đổi tên event trước khi gửi (map taxonomy UniTrack → GA4). */
  eventNames?: Record<string, string>;
  /** Tên hàm gtag nếu trang đặt khác. Default 'gtag'. */
  gtagName?: string;
}

/** GA4 chỉ nhận [a-z0-9_], bắt đầu bằng chữ, tối đa 40 ký tự. */
function safeName(raw: string): string {
  let s = raw.toLowerCase().replace(/[^a-z0-9_]/g, '_').replace(/_+/g, '_');
  if (!/^[a-z]/.test(s)) s = 'e_' + s;
  return s.slice(0, 40);
}

function safeParams(props: EventProperties): EventProperties {
  const out: EventProperties = {};
  let n = 0;
  for (const [k, v] of Object.entries(props)) {
    if (n >= 25) break;                       // GA4 bỏ im lặng phần dư
    if (v === undefined || v === null) continue;
    const key = safeName(k);
    out[key] = typeof v === 'string' ? v.slice(0, 100)
             : typeof v === 'object' ? JSON.stringify(v).slice(0, 100)
             : v;
    n++;
  }
  return out;
}

export class GA4Provider implements AnalyticsProvider {
  readonly name = 'GA4';
  constructor(private cfg: GA4ProviderConfig = {}) {}

  private gtag(...args: unknown[]): void {
    const fn = (window as unknown as Record<string, unknown>)[this.cfg.gtagName || 'gtag'];
    if (typeof fn === 'function') { (fn as (...a: unknown[]) => void)(...args); return; }
    // gtag chưa nạp xong → đẩy thẳng vào dataLayer, gtag sẽ tiêu thụ sau.
    const w = window as unknown as { dataLayer?: unknown[] };
    (w.dataLayer = w.dataLayer || []).push(args);
  }

  track(name: EventName, props: EventProperties): void {
    const mapped = this.cfg.eventNames?.[name] || name;
    this.gtag('event', safeName(mapped), safeParams(props));
  }

  setUser(userId: string | null): void {
    // user_id của GA4 — đã hash sẵn ở tầng UniTrack nếu bật piiSalt.
    this.gtag('set', { user_id: userId ?? undefined });
  }

  setScreen(name: string): void {
    this.gtag('event', 'page_view', { page_path: name.slice(0, 100) });
  }
}

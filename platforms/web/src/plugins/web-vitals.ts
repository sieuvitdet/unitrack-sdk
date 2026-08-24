// Web Vitals — LCP / CLS / INP / TTFB / FCP.
//
// Dùng PerformanceObserver gốc của trình duyệt, KHÔNG kéo thư viện web-vitals
// (~5KB + phải theo nhịp release của nó). Ba chỉ số chính đều là entry chuẩn:
//   LCP → 'largest-contentful-paint'
//   CLS → 'layout-shift' (cộng dồn theo cụm, xem giải thích bên dưới)
//   INP → 'event' với durationThreshold (Chromium; Safari/FF chưa có)
//
// Ngưỡng "tốt/cần cải thiện/kém" lấy theo Google, gửi kèm luôn để phía phân
// tích không phải tự nhớ mốc.

import type { CapturePlugin, EventName, EventProperties } from '../types';

type Emit = (name: EventName, props: EventProperties) => void;

/** Ngưỡng Google: [tốt, kém]. Dưới ngưỡng đầu = good, trên ngưỡng sau = poor. */
const THRESHOLDS: Record<string, [number, number]> = {
  LCP:  [2500, 4000],
  CLS:  [0.1, 0.25],
  INP:  [200, 500],
  FCP:  [1800, 3000],
  TTFB: [800, 1800],
};

function rate(metric: string, value: number): string {
  const t = THRESHOLDS[metric];
  if (!t) return 'unknown';
  return value <= t[0] ? 'good' : value <= t[1] ? 'needs_improvement' : 'poor';
}

export interface WebVitalsOptions {
  /** Tên event. Default 'web_vital'. */
  eventName?: string;
}

export function webVitalsPlugin(opts: WebVitalsOptions = {}): CapturePlugin {
  const eventName = opts.eventName ?? 'web_vital';

  return {
    name: 'WebVitals',
    install(emit: Emit) {
      if (typeof PerformanceObserver === 'undefined') return;
      const observers: PerformanceObserver[] = [];
      const sent = new Set<string>();

      const report = (metric: string, value: number, extra: EventProperties = {}) => {
        // Mỗi chỉ số chỉ gửi một lần mỗi lượt tải trang — LCP/CLS thay đổi
        // liên tục, gửi mỗi lần đổi sẽ ngập event và số cuối mới là số đúng.
        if (sent.has(metric)) return;
        sent.add(metric);
        const v = Math.round(value * 1000) / 1000;
        emit(eventName, { metric, value: v, rating: rate(metric, v), ...extra });
      };

      const observe = (type: string, cb: (list: PerformanceEntryList) => void, extra?: PerformanceObserverInit) => {
        try {
          const po = new PerformanceObserver((list) => cb(list.getEntries()));
          // `buffered: true` lấy cả entry xảy ra TRƯỚC khi observer gắn vào —
          // thiếu nó thì LCP/FCP của lần tải đầu mất trắng vì chúng bắn sớm
          // hơn lúc SDK khởi tạo.
          po.observe({ type, buffered: true, ...extra } as PerformanceObserverInit);
          observers.push(po);
        } catch { /* trình duyệt không hỗ trợ loại entry này */ }
      };

      // ── LCP: giữ entry cuối cùng, chốt khi người dùng rời/ẩn trang ──────
      let lcp = 0;
      observe('largest-contentful-paint', (entries) => {
        const last = entries[entries.length - 1] as PerformanceEntry & { startTime: number };
        if (last) lcp = last.startTime;
      });

      // ── CLS: cộng dồn theo "cụm" (session window) ───────────────────────
      // Không cộng tất cả layout-shift vào một số: một trang sống lâu sẽ tích
      // luỹ vô hạn. Google định nghĩa CLS = cụm nặng nhất, cụm ngắt khi cách
      // nhau >1s hoặc kéo dài >5s.
      let cls = 0, clusterValue = 0, clusterFirst = 0, clusterLast = 0;
      observe('layout-shift', (entries) => {
        for (const e of entries as Array<PerformanceEntry & { value: number; hadRecentInput: boolean }>) {
          if (e.hadRecentInput) continue;   // dịch chuyển do user bấm → không tính
          if (clusterValue && (e.startTime - clusterLast > 1000 || e.startTime - clusterFirst > 5000)) {
            clusterValue = 0;
          }
          if (!clusterValue) clusterFirst = e.startTime;
          clusterLast = e.startTime;
          clusterValue += e.value;
          if (clusterValue > cls) cls = clusterValue;
        }
      });

      // ── INP: tương tác chậm nhất. Chỉ Chromium có 'event' entry ─────────
      let inp = 0;
      observe('event', (entries) => {
        for (const e of entries as Array<PerformanceEntry & { duration: number; interactionId?: number }>) {
          if (!e.interactionId) continue;   // chỉ tính tương tác thật
          if (e.duration > inp) inp = e.duration;
        }
      }, { durationThreshold: 40 } as PerformanceObserverInit);

      // ── FCP + TTFB: có ngay, gửi luôn ───────────────────────────────────
      observe('paint', (entries) => {
        for (const e of entries) {
          if (e.name === 'first-contentful-paint') report('FCP', e.startTime);
        }
      });
      const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
      if (nav && nav.responseStart > 0) report('TTFB', nav.responseStart);

      // ── Chốt số cuối khi trang ẩn đi ────────────────────────────────────
      // Dùng visibilitychange chứ không phải 'unload': trên mobile trình duyệt
      // có thể giết tab mà không bao giờ bắn unload.
      const finalize = () => {
        if (lcp > 0) report('LCP', lcp);
        if (cls > 0) report('CLS', cls);
        if (inp > 0) report('INP', inp);
      };
      const onHide = () => { if (document.visibilityState === 'hidden') finalize(); };
      document.addEventListener('visibilitychange', onHide);
      window.addEventListener('pagehide', finalize);

      return () => {
        observers.forEach((o) => o.disconnect());
        document.removeEventListener('visibilitychange', onHide);
        window.removeEventListener('pagehide', finalize);
      };
    },
  };
}

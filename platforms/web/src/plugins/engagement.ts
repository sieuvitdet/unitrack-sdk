// Engagement — scroll depth, rage click, dead click.
//
// Ba tín hiệu nói lên chất lượng trải nghiệm mà screen_view/click đơn thuần
// không thấy được:
//   scroll depth — người dùng có đọc tới đâu không, hay thoát ngay đầu trang
//   rage click   — bấm dồn dập một chỗ: UI hỏng, hoặc người dùng đang bực
//   dead click   — bấm vào thứ trông bấm được nhưng không có gì xảy ra

import type { CapturePlugin, EventName, EventProperties } from '../types';

type Emit = (name: EventName, props: EventProperties) => void;

export interface EngagementOptions {
  /** Các mốc % cuộn cần báo. Default 25/50/75/100. */
  scrollMilestones?: number[];
  /** Số lần bấm trong `rageWindowMs` tại cùng một chỗ để coi là rage. Default 3. */
  rageThreshold?: number;
  rageWindowMs?: number;
  /** Bán kính (px) coi là "cùng một chỗ". Default 32. */
  rageRadiusPx?: number;
  /** Bỏ qua dead click — mặc định BẬT vì nó dễ dương tính giả trên SPA. */
  trackDeadClick?: boolean;
}

export function engagementPlugin(opts: EngagementOptions = {}): CapturePlugin {
  const milestones = (opts.scrollMilestones ?? [25, 50, 75, 100]).slice().sort((a, b) => a - b);
  const rageThreshold = opts.rageThreshold ?? 3;
  const rageWindowMs = opts.rageWindowMs ?? 1000;
  const rageRadius = opts.rageRadiusPx ?? 32;
  const trackDead = opts.trackDeadClick ?? false;

  return {
    name: 'Engagement',
    install(emit: Emit) {
      // ── Scroll depth ────────────────────────────────────────────────────
      const reached = new Set<number>();
      let ticking = false;

      const measure = () => {
        ticking = false;
        const doc = document.documentElement;
        const scrollable = doc.scrollHeight - window.innerHeight;
        // Trang ngắn hơn màn hình → coi như đã xem hết, nhưng không báo mốc
        // nào cả: "cuộn 100%" trên trang không cuộn được là số vô nghĩa.
        if (scrollable <= 0) return;
        const pct = Math.min(100, Math.round(((window.scrollY + window.innerHeight) / doc.scrollHeight) * 100));
        for (const m of milestones) {
          if (pct >= m && !reached.has(m)) {
            reached.add(m);
            emit('scroll_depth', { percent: m, screen: location.pathname });
          }
        }
      };
      const onScroll = () => {
        // rAF gộp nhiều sự kiện scroll thành một phép đo — scroll bắn hàng
        // trăm lần mỗi giây, đo mỗi lần là phí CPU của trang chủ nhà.
        if (ticking) return;
        ticking = true;
        requestAnimationFrame(measure);
      };
      window.addEventListener('scroll', onScroll, { passive: true });
      measure();   // đo ngay: trang có thể đã ở giữa do khôi phục vị trí cuộn

      // ── Rage click ──────────────────────────────────────────────────────
      let hits: Array<{ x: number; y: number; t: number }> = [];
      const onClick = (ev: MouseEvent) => {
        const now = Date.now();
        hits = hits.filter((h) => now - h.t < rageWindowMs);
        hits.push({ x: ev.clientX, y: ev.clientY, t: now });

        const near = hits.filter((h) =>
          Math.hypot(h.x - ev.clientX, h.y - ev.clientY) <= rageRadius);
        if (near.length >= rageThreshold) {
          const el = ev.target as HTMLElement | null;
          emit('rage_click', {
            screen: location.pathname,
            clicks: near.length,
            element_key: el?.getAttribute('data-track-id') || el?.id || el?.tagName?.toLowerCase(),
          });
          hits = [];   // đã báo → reset, tránh bắn liên tục cho cùng một cơn
        }
      };
      document.addEventListener('click', onClick, true);

      // ── Dead click (tuỳ chọn) ───────────────────────────────────────────
      // Bấm mà 500ms sau DOM không đổi và URL không đổi → nghi là bấm hụt.
      // Mặc định TẮT: SPA cập nhật bất đồng bộ nhiều, dễ báo nhầm.
      let deadObserver: MutationObserver | null = null;
      const onMaybeDead = (ev: MouseEvent) => {
        const el = ev.target as HTMLElement | null;
        if (!el) return;
        const urlBefore = location.href;
        let mutated = false;
        deadObserver?.disconnect();
        deadObserver = new MutationObserver(() => { mutated = true; });
        deadObserver.observe(document.body, { childList: true, subtree: true, attributes: true });
        setTimeout(() => {
          deadObserver?.disconnect();
          if (!mutated && location.href === urlBefore) {
            emit('dead_click', {
              screen: location.pathname,
              element_key: el.getAttribute('data-track-id') || el.id || el.tagName.toLowerCase(),
            });
          }
        }, 500);
      };
      if (trackDead) document.addEventListener('click', onMaybeDead, true);

      return () => {
        window.removeEventListener('scroll', onScroll);
        document.removeEventListener('click', onClick, true);
        if (trackDead) document.removeEventListener('click', onMaybeDead, true);
        deadObserver?.disconnect();
      };
    },
  };
}

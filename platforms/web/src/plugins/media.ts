// Media tracking — <video> / <audio>.
//
// Bắt play / pause / seek / ended + mốc % đã xem (10/25/50/75/95).
//
// Không cần đăng ký từng player: media event (play, pause, ended…) không nổi
// bọt, nhưng CÓ đi qua giai đoạn capture, nên một listener ở document bắt được
// mọi phần tử, kể cả cái được thêm vào DOM sau. Đây là lý do không dùng
// querySelectorAll lúc install như hướng dẫn thường thấy.

import type { CapturePlugin, EventName, EventProperties } from '../types';

type Emit = (name: EventName, props: EventProperties) => void;

export interface MediaOptions {
  /** Mốc % phát cần báo. Default 10/25/50/75/95. */
  milestones?: number[];
}

function mediaId(el: HTMLMediaElement): string {
  return el.getAttribute('data-track-id')
      || el.id
      || el.getAttribute('title')
      // src có thể là blob: hoặc chứa token — chỉ lấy phần tên file.
      || (el.currentSrc || el.src || '').split('/').pop()?.split('?')[0]
      || el.tagName.toLowerCase();
}

function base(el: HTMLMediaElement): EventProperties {
  return {
    media_id: mediaId(el),
    media_type: el.tagName.toLowerCase(),   // video | audio
    duration_sec: Number.isFinite(el.duration) ? Math.round(el.duration) : undefined,
    position_sec: Math.round(el.currentTime),
    screen: location.pathname,
  };
}

export function mediaPlugin(opts: MediaOptions = {}): CapturePlugin {
  const milestones = (opts.milestones ?? [10, 25, 50, 75, 95]).slice().sort((a, b) => a - b);

  return {
    name: 'Media',
    install(emit: Emit) {
      // Mốc đã báo, theo từng phần tử. WeakMap để phần tử bị gỡ khỏi DOM thì
      // bộ nhớ tự thu hồi, không giữ tham chiếu sống.
      const passed = new WeakMap<HTMLMediaElement, Set<number>>();
      let seekingFrom: number | null = null;

      const isMedia = (t: EventTarget | null): t is HTMLMediaElement =>
        t instanceof HTMLMediaElement;

      const on = (type: string, handler: (el: HTMLMediaElement, ev: Event) => void) => {
        const fn = (ev: Event) => { if (isMedia(ev.target)) handler(ev.target, ev); };
        document.addEventListener(type, fn, true);   // capture — media event không bubble
        return () => document.removeEventListener(type, fn, true);
      };

      const offs = [
        on('play',   (el) => emit('media_play',   base(el))),
        on('pause',  (el) => {
          // `pause` cũng bắn ngay trước `ended` — bỏ để không đếm hai lần.
          if (el.ended) return;
          emit('media_pause', base(el));
        }),
        on('ended',  (el) => emit('media_ended',  base(el))),
        on('seeking', (el) => { seekingFrom = el.currentTime; }),
        on('seeked', (el) => {
          emit('media_seek', { ...base(el), from_sec: seekingFrom === null ? undefined : Math.round(seekingFrom) });
          seekingFrom = null;
        }),
        on('timeupdate', (el) => {
          if (!Number.isFinite(el.duration) || el.duration <= 0) return;
          const pct = (el.currentTime / el.duration) * 100;
          let set = passed.get(el);
          if (!set) { set = new Set(); passed.set(el, set); }
          for (const m of milestones) {
            if (pct >= m && !set.has(m)) {
              set.add(m);
              emit('media_progress', { ...base(el), percent: m });
            }
          }
        }),
        on('error', (el) => emit('media_error', {
          ...base(el),
          error_code: el.error?.code,
          error_message: el.error?.message || undefined,
        })),
      ];

      return () => offs.forEach((f) => f());
    },
  };
}

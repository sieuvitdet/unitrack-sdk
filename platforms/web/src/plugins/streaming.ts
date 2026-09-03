// Streaming — đo chất lượng truyền video trực tiếp (WebRTC / HLS / MJPEG).
//
// Khác `mediaPlugin`: cái kia đo HÀNH VI người dùng (play, pause, seek, % xem),
// cái này đo CHẤT LƯỢNG ĐƯỜNG TRUYỀN — thứ quyết định người dùng có xem được
// hay không:
//
//   stream_connecting      bắt đầu kết nối
//   stream_first_frame     khung hình đầu tiên hiện ra  ← chỉ số quan trọng nhất
//   stream_stalled         đang xem thì khựng (buffer rỗng)
//   stream_resumed         chạy lại sau khi khựng, kèm thời gian gián đoạn
//   stream_reconnecting    WebRTC rớt, đang thử nối lại
//   stream_failed          bỏ cuộc
//   stream_ended           kết thúc bình thường
//   stream_stats           mẫu định kỳ: bitrate, khung rớt, độ trễ
//
// Ba nguồn tín hiệu, vì mỗi công nghệ báo một kiểu:
//   <video>            → waiting / playing / stalled / loadeddata
//   RTCPeerConnection  → connectionstatechange + getStats()
//   <img> MJPEG        → load / error (camera đời cũ, không có sự kiện nào khác)

import type { CapturePlugin, EventName, EventProperties } from '../types';
import { monoNow } from '../mono-clock';

type Emit = (name: EventName, props: EventProperties) => void;

export interface StreamingOptions {
  /** Nhịp lấy mẫu chất lượng (ms). 0 = tắt. Default 30000. */
  statsIntervalMs?: number;
  /** Khựng ngắn hơn ngưỡng này thì bỏ qua — mạng nào cũng có nấc nhỏ, báo hết
   * sẽ ngập event mà không nói lên điều gì. Default 500ms. */
  minStallMs?: number;
  /** Theo dõi cả <img> MJPEG. Default false: trang nhiều ảnh sẽ ồn. */
  trackMjpeg?: boolean;
  /** Chỉ theo dõi <img> khớp selector này khi bật trackMjpeg. */
  mjpegSelector?: string;
}

function streamId(el: Element): string {
  return el.getAttribute('data-track-id')
      || el.id
      // KHÔNG lấy src: URL stream hay chứa token phiên hoặc IP camera nội bộ.
      || el.tagName.toLowerCase();
}

export function streamingPlugin(opts: StreamingOptions = {}): CapturePlugin {
  const statsMs = opts.statsIntervalMs ?? 30_000;
  const minStall = opts.minStallMs ?? 500;

  return {
    name: 'Streaming',
    install(emit: Emit) {
      const cleanups: Array<() => void> = [];

      // ── <video>: vòng đời phát ─────────────────────────────────────────
      // Mốc bắt đầu tính theo từng phần tử, không dùng biến chung: trang lưới
      // camera có nhiều video chạy song song.
      const startedAt = new WeakMap<HTMLMediaElement, number>();
      const stalledAt = new WeakMap<HTMLMediaElement, number>();
      const gotFrame = new WeakSet<HTMLMediaElement>();

      const isMedia = (t: EventTarget | null): t is HTMLMediaElement =>
        t instanceof HTMLMediaElement;

      const on = (type: string, fn: (el: HTMLMediaElement) => void) => {
        const h = (ev: Event) => { if (isMedia(ev.target)) fn(ev.target); };
        // capture: true — sự kiện media không nổi bọt, và cách này bắt được cả
        // phần tử được thêm vào DOM sau khi plugin đã cài.
        document.addEventListener(type, h, true);
        cleanups.push(() => document.removeEventListener(type, h, true));
      };

      const base = (el: HTMLMediaElement): EventProperties => ({
        stream_id: streamId(el),
        stream_type: el.tagName.toLowerCase(),
        screen: location.pathname,
      });

      on('loadstart', (el) => {
        startedAt.set(el, monoNow());
        gotFrame.delete(el);
        emit('stream_connecting', base(el));
      });

      // `loadeddata` = đã có khung hình đầu để vẽ. Đây là thời điểm người dùng
      // THẬT SỰ thấy hình, khác với `canplay` (mới đủ dữ liệu để bắt đầu).
      on('loadeddata', (el) => {
        if (gotFrame.has(el)) return;
        gotFrame.add(el);
        const t0 = startedAt.get(el);
        emit('stream_first_frame', {
          ...base(el),
          ttff_ms: t0 ? monoNow() - t0 : undefined,   // time to first frame
        });
      });

      const markStall = (el: HTMLMediaElement) => {
        if (stalledAt.has(el)) return;                  // đã đang khựng
        stalledAt.set(el, monoNow());
      };
      on('waiting', markStall);
      on('stalled', markStall);

      on('playing', (el) => {
        const s0 = stalledAt.get(el);
        if (s0 === undefined) return;
        stalledAt.delete(el);
        const gap = monoNow() - s0;
        if (gap < minStall) return;                     // nấc nhỏ, bỏ qua
        emit('stream_stalled', { ...base(el), stall_ms: gap });
        emit('stream_resumed', { ...base(el), stall_ms: gap });
      });

      on('ended', (el) => {
        const t0 = startedAt.get(el);
        emit('stream_ended', {
          ...base(el),
          watched_ms: t0 ? monoNow() - t0 : undefined,
        });
      });

      on('error', (el) => {
        emit('stream_failed', {
          ...base(el),
          error_code: el.error?.code,
          // Thông điệp lỗi của trình duyệt có thể kèm URL → cắt ngắn để token
          // trong URL stream không đi theo vào event.
          error_message: el.error?.message?.slice(0, 80) || undefined,
        });
      });

      // ── Lấy mẫu chất lượng định kỳ ─────────────────────────────────────
      // `getVideoPlaybackQuality()` là API chuẩn, có ở mọi trình duyệt hiện
      // đại — không cần đợi WebRTC mới đo được khung rớt.
      let statsTimer: ReturnType<typeof setInterval> | null = null;
      if (statsMs > 0) {
        const lastDropped = new WeakMap<HTMLVideoElement, number>();
        statsTimer = setInterval(() => {
          // Chỉ đo video đang chạy và đang hiển thị — tab ẩn thì số liệu vô
          // nghĩa vì trình duyệt tự hãm giải mã.
          if (document.visibilityState !== 'visible') return;
          document.querySelectorAll('video').forEach((v) => {
            if (v.paused || v.ended || !v.videoWidth) return;
            const q = v.getVideoPlaybackQuality?.();
            if (!q) return;
            const prev = lastDropped.get(v) ?? 0;
            const dropped = q.droppedVideoFrames - prev;
            lastDropped.set(v, q.droppedVideoFrames);
            emit('stream_stats', {
              ...base(v),
              width: v.videoWidth,
              height: v.videoHeight,
              dropped_frames: dropped,
              total_frames: q.totalVideoFrames,
              // buffered cuối - currentTime = còn bao nhiêu giây dự trữ.
              // Tụt về 0 là sắp khựng.
              buffer_ahead_sec: v.buffered.length
                ? Math.round((v.buffered.end(v.buffered.length - 1) - v.currentTime) * 10) / 10
                : 0,
            });
          });
        }, statsMs);
        cleanups.push(() => { if (statsTimer) clearInterval(statsTimer); });
      }

      // ── WebRTC ─────────────────────────────────────────────────────────
      // Vá RTCPeerConnection để mọi kết nối tạo SAU khi plugin cài đều được
      // theo dõi — app thường tạo peer connection lúc người dùng bấm xem, tức
      // muộn hơn lúc SDK khởi tạo.
      const RTC = (window as unknown as { RTCPeerConnection?: typeof RTCPeerConnection })
        .RTCPeerConnection;
      if (typeof RTC === 'function') {
        const Orig = RTC;
        const Patched = function (this: unknown, ...args: unknown[]) {
          const pc = new (Orig as unknown as new (...a: unknown[]) => RTCPeerConnection)(...args);
          const t0 = monoNow();
          let connectedAt = 0;

          pc.addEventListener('connectionstatechange', () => {
            const st = pc.connectionState;
            const p: EventProperties = { transport: 'webrtc', screen: location.pathname };
            if (st === 'connecting') {
              emit('stream_connecting', p);
            } else if (st === 'connected') {
              connectedAt = monoNow();
              emit('stream_first_frame', { ...p, ttff_ms: Math.max(0, monoNow() - t0) });
            } else if (st === 'disconnected') {
              // 'disconnected' của WebRTC thường tự hồi — báo là "đang nối lại"
              // chứ không phải thất bại, nếu không sẽ thổi phồng tỉ lệ lỗi.
              emit('stream_reconnecting', p);
            } else if (st === 'failed') {
              emit('stream_failed', { ...p, error_code: 'ice_failed' });
            } else if (st === 'closed') {
              emit('stream_ended', {
                ...p,
                watched_ms: connectedAt ? monoNow() - connectedAt : undefined,
              });
            }
          });
          return pc;
        } as unknown as typeof RTCPeerConnection;
        Patched.prototype = Orig.prototype;
        (window as unknown as Record<string, unknown>).RTCPeerConnection = Patched;
        cleanups.push(() => {
          (window as unknown as Record<string, unknown>).RTCPeerConnection = Orig;
        });
      }

      // ── MJPEG qua <img> ────────────────────────────────────────────────
      // Camera đời cũ phát MJPEG vào thẻ <img>: không có sự kiện nào ngoài
      // load/error, nên đây là tất cả những gì đo được.
      if (opts.trackMjpeg) {
        const sel = opts.mjpegSelector || 'img[data-stream]';
        const onImg = (ev: Event) => {
          const el = ev.target as HTMLElement | null;
          if (!(el instanceof HTMLImageElement) || !el.matches(sel)) return;
          emit(ev.type === 'error' ? 'stream_failed' : 'stream_first_frame', {
            stream_id: streamId(el),
            stream_type: 'mjpeg',
            screen: location.pathname,
          });
        };
        document.addEventListener('load', onImg, true);
        document.addEventListener('error', onImg, true);
        cleanups.push(() => {
          document.removeEventListener('load', onImg, true);
          document.removeEventListener('error', onImg, true);
        });
      }

      return () => cleanups.forEach((f) => f());
    },
  };
}

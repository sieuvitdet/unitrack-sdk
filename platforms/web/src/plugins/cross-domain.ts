// Cross-domain linking — giữ session khi người dùng đi sang domain khác.
//
// Vấn đề: localStorage bị cô lập theo origin, nên rời shop.example.com sang
// checkout.example.net là mất session — một hành trình mua hàng bị cắt làm hai
// người dùng khác nhau.
//
// Cách làm: gắn tham số `_sp` vào link ra ngoài, trang đích đọc lại và nối
// tiếp session. Dùng ĐÚNG tên `_sp` và định dạng của Snowplow
// (`domainUserId.timestamp.sessionId.subjectUserId.sourceId.sourcePlatform`)
// để đường dữ liệu nào đang parse `_sp` sẵn thì vẫn hiểu được.
//
// Chỉ trang trí link mà app khai báo qua `shouldDecorate` — quét bừa mọi link
// ra ngoài sẽ rò session_id sang bên thứ ba (mạng quảng cáo, CDN).

import type { CapturePlugin, EventName, EventProperties } from '../types';

type Emit = (name: EventName, props: EventProperties) => void;

export interface CrossDomainOptions {
  /** Trả true nếu link này được phép mang session sang. BẮT BUỘC — không có
   * mặc định "trang trí tất cả" vì đó là rò rỉ dữ liệu. */
  shouldDecorate: (link: HTMLAnchorElement) => boolean;
  /** Lấy session hiện tại. Thường truyền `() => UniTrack.currentSessionId()`. */
  getSessionId: () => string;
  /** ID người dùng đã hash, nếu có. */
  getUserId?: () => string | null;
  /** Tên nguồn để trang đích biết khách tới từ đâu. */
  sourceId?: string;
}

/** Đọc `_sp` ở trang đích. Gọi TRƯỚC `UniTrack.initialize()` để nối session. */
export function readCrossDomainSession(): {
  sessionId?: string; userId?: string; sourceId?: string; ageMs?: number;
} | null {
  try {
    const raw = new URLSearchParams(location.search).get('_sp');
    if (!raw) return null;
    // Format Snowplow dùng '.' làm phân tách nên sourceId KHÔNG được chứa dấu
    // chấm. Nhưng mặc định cũ lấy `location.hostname` ('shop.vn') làm sourceId,
    // và những link đã phát tán ngoài kia vẫn mang dạng đó — split thường sẽ
    // cắt 'shop.vn' thành 'shop'. Tách 4 phần đầu, phần cuối là platform, còn
    // lại gộp về sourceId.
    const seg = raw.split('.');
    const [domainUserId, ts, sessionId, subjectUserId] = seg;
    const sourceId = seg.length > 5
      ? seg.slice(4, -1).join('.')   // sourceId có dấu chấm (link cũ)
      : seg[4];
    const age = ts ? Date.now() - Number(ts) : undefined;
    // Link cũ quá thì bỏ: người ta có thể chia sẻ URL đã trang trí lên chat,
    // người khác bấm vào sẽ thừa hưởng nhầm session của người gửi.
    if (age !== undefined && (Number.isNaN(age) || age > 5 * 60 * 1000)) return null;
    return {
      sessionId: sessionId || domainUserId || undefined,
      userId: subjectUserId || undefined,
      sourceId: sourceId || undefined,
      ageMs: age,
    };
  } catch {
    return null;
  }
}

export function crossDomainPlugin(opts: CrossDomainOptions): CapturePlugin {
  return {
    name: 'CrossDomain',
    install(emit: Emit) {
      const decorate = (link: HTMLAnchorElement) => {
        try {
          const url = new URL(link.href, location.href);
          if (url.origin === location.origin) return;     // cùng nhà, không cần
          if (url.searchParams.has('_sp')) return;          // đã trang trí rồi
          if (!opts.shouldDecorate(link)) return;

          const parts = [
            opts.getSessionId() || '',            // domainUserId — web dùng chung session
            String(Date.now()),
            opts.getSessionId() || '',            // sessionId
            opts.getUserId?.() || '',
            // '.' là ký tự phân tách của format — sourceId chứa nó sẽ làm
            // trang đích parse sai. Đổi sang '-' khi rơi về hostname.
            (opts.sourceId || location.hostname).replace(/\./g, '-'),
            'web',
          ];
          url.searchParams.set('_sp', parts.join('.'));
          link.href = url.toString();

          emit('cross_domain_link', {
            target_host: url.host,
            screen: location.pathname,
            element_key: link.getAttribute('data-track-id') || link.id || undefined,
          });
        } catch { /* href không parse được */ }
      };

      // Trang trí lúc BẤM, không phải lúc tải trang: link có thể được thêm vào
      // sau, href có thể đổi, và session_id phải là cái tại thời điểm rời đi.
      // capture:true để chạy trước handler của app.
      const onClick = (ev: MouseEvent) => {
        const a = (ev.target as HTMLElement | null)?.closest?.('a');
        if (a instanceof HTMLAnchorElement && a.href) decorate(a);
      };
      // `auxclick` cho chuột giữa (mở tab mới), `contextmenu` cho "sao chép
      // địa chỉ link" — cả hai đều là đường rời trang mà click thường bỏ sót.
      document.addEventListener('click', onClick, true);
      document.addEventListener('auxclick', onClick, true);
      document.addEventListener('contextmenu', onClick, true);

      return () => {
        document.removeEventListener('click', onClick, true);
        document.removeEventListener('auxclick', onClick, true);
        document.removeEventListener('contextmenu', onClick, true);
      };
    },
  };
}

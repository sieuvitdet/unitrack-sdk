// Cầu nối tới SDK analytics đã có sẵn trên trang.
//
// Mixpanel, Amplitude, Segment, PostHog, Heap… đều cùng một hình dạng:
//   track(name, props) · identify(userId) · một hàm nào đó cho screen/page.
// Viết 5 provider gần giống nhau là thừa — một cầu nối nhận vào 3 hàm là đủ,
// và app tự nối tới SDK nào cũng được, kể cả SDK nội bộ của công ty.
//
// KHÔNG tự nạp script của bên thứ ba: trang đã nạp rồi thì nạp lần hai sinh
// hai instance đá nhau; chưa nạp thì việc nạp là quyết định của trang, không
// phải của thư viện tracking.

import type { AnalyticsProvider, EventName, EventProperties } from '../types';

export interface SdkBridgeConfig {
  /** Tên hiện trong log. */
  name: string;
  /** Bắt buộc — nơi event đi tới. */
  track: (name: string, props: EventProperties) => void;
  /** Gắn định danh người dùng. */
  identify?: (userId: string | null, traits: EventProperties) => void;
  /** Báo đổi màn / trang. */
  page?: (screen: string) => void;
  /** Lọc: trả false để chặn event khỏi provider này. Dùng khi bên thứ ba tính
   * tiền theo lượng event — chỉ đẩy sang cái thật sự cần. */
  filter?: (name: string, props: EventProperties) => boolean;
  /** Đổi tên event cho khớp taxonomy của bên nhận. */
  eventNames?: Record<string, string>;
}

export class SdkBridgeProvider implements AnalyticsProvider {
  readonly name: string;
  constructor(private cfg: SdkBridgeConfig) {
    this.name = cfg.name;
  }

  track(name: EventName, props: EventProperties): void {
    if (this.cfg.filter && !this.cfg.filter(name, props)) return;
    const mapped = this.cfg.eventNames?.[name] || name;
    // Lỗi của bên thứ ba không được kéo sập fan-out sang provider còn lại.
    try { this.cfg.track(mapped, props); } catch { /* nuốt có chủ đích */ }
  }

  setUser(userId: string | null, traits: EventProperties): void {
    try { this.cfg.identify?.(userId, traits); } catch { /* như trên */ }
  }

  setScreen(screen: string): void {
    try { this.cfg.page?.(screen); } catch { /* như trên */ }
  }
}

// Public type surface — kept stable for downstream apps.

export interface UniTrackConfig {
  /** Backend HTTP ingest URL. Empty → core HTTP provider không gửi gì,
   * SDK chỉ fan-out qua provider thứ 3 (Snowplow). Giống pattern Flutter. */
  endpoint?: string;

  /** Auto-capture master toggle. Default true. */
  autoCapture?: boolean;

  /** Bắt route change (popstate + history.pushState/replaceState patch). */
  trackScreens?: boolean;

  /** Bắt document-level click qua capture-phase listener. */
  trackTaps?: boolean;

  /** Patch fetch + XMLHttpRequest để emit network_request/error event. */
  trackNetwork?: boolean;

  /** app_start + app_foreground/app_background qua visibilitychange. */
  trackLifecycle?: boolean;

  /** Tỉ lệ phiên được thu thập, 0.0–1.0. Default 1 (lấy hết).
   * Quyết định một lần cho cả phiên theo session_id, không random từng event.
   * Event `crash` luôn gửi bất kể tỉ lệ — parity native. */
  samplingRate?: number;

  /** true → SDK im lặng cho tới khi app gọi `setConsent(true)`.
   * Dành cho GDPR/CCPA: chờ user bấm đồng ý trên banner cookie rồi mới thu. */
  requireConsent?: boolean;

  /** Thu thập ẩn danh. Hai mức, theo mô hình Snowplow:
   *
   *  'session' — bỏ định danh người dùng, GIỮ session. Vẫn phân tích được
   *              hành vi trong một phiên, nhưng không nối được các phiên của
   *              cùng một người. Vẫn ghi localStorage.
   *  'full'    — bỏ cả định danh lẫn session, KHÔNG ghi gì vào trình duyệt.
   *              Mỗi lần tải trang là một phiên mới. Dùng khi chưa có consent
   *              mà vẫn muốn đếm lưu lượng.
   *
   * Bỏ trống = tắt (thu thập bình thường). */
  anonymousTracking?: 'session' | 'full';

  /** Đọc `_sp` trong URL để nối tiếp session từ domain khác. Default true —
   * chỉ có tác dụng khi trang nguồn có gắn `crossDomainPlugin`. */
  crossDomainSession?: boolean;

  /** Số event mỗi batch flush. Default 10. */
  batchSize?: number;

  /** Interval flush (ms) khi queue chưa đầy batch. Default 3000. */
  flushIntervalMs?: number;

  /** Session timeout (ms) — quá thời gian không activity → rotate session_id.
   * Default 30 phút. */
  sessionTimeoutMs?: number;

  /** PII salt — hash SHA-256(salt + raw) cho user_id/phone/email khi identify. */
  piiSalt?: string;

  /** W3C trace context allowlist. Empty list = fail-closed (không inject
   * `traceparent` header vào bất kỳ request nào). */
  tracingAllowlistHosts?: string[];

  /** Custom event name overrides — đổi tên 4 event auto-capture mà không cần
   * rebuild app code. Match pattern Flutter `sdk_config.screen_*_event`. */
  screenStartEvent?: string;       // default 'screen_viewed'
  screenEndEvent?: string;         // default 'screen_exited'
  screenLoadEvent?: string;        // default 'screen_load_completed'
  clickEvent?: string;             // default 'click'

  /** Verbose console.log mỗi event. Default true ở dev — bật/tắt qua flag. */
  verboseLogging?: boolean;
}

export type EventName = string;
export type EventProperties = Record<string, unknown>;

export interface AnalyticsProvider {
  /** Tên provider, log debug. */
  readonly name: string;
  /** Gọi 1 lần sau khi SDK initialize. */
  init?(): void | Promise<void>;
  /** Mỗi event UniTrack core nhận → fan-out qua đây. */
  track(name: EventName, props: EventProperties): void | Promise<void>;
  /** Identify user — provider tự cache state. */
  setUser?(userId: string | null, traits: EventProperties): void;
  /** Update screen name. */
  setScreen?(name: string): void;
}

/** Plugin ĐẦU VÀO — bắt thêm loại event mà auto-capture lõi không lo.
 *
 * Khác `AnalyticsProvider` (đầu ra: event đi tới đâu). Một bên quyết định
 * *bắt gì*, một bên quyết định *gửi đâu*. Cùng mô hình plugin của Snowplow
 * browser tracker, nhưng plugin ở đây chỉ cần một hàm `install`.
 *
 * Không nằm trong bundle lõi: app tự `import` cái mình cần rồi truyền vào
 * `plugins`, nên trang không dùng video thì không tải code media. */
export interface CapturePlugin {
  readonly name: string;
  /** Gọi một lần sau khi SDK khởi tạo. `emit` chính là `UniTrack.track`.
   * Trả về hàm dọn dẹp nếu plugin có gắn listener cần gỡ. */
  install(emit: (name: EventName, props: EventProperties) => void): void | (() => void);
}

export interface TraceIds {
  traceId: string;   // 32-char lowercase hex
  spanId: string;    // 16-char lowercase hex
}

/** Row đã dựng sẵn nằm chờ trong offline queue. Lưu nguyên dạng sắp POST
 * (không phải {name, props}) để lúc replay giữ NGUYÊN `event_id` và
 * `timestamp` gốc — dựng lại sẽ sinh id mới, portal mất khả năng chống trùng
 * và mốc thời gian nhảy về lúc gửi lại thay vì lúc user thao tác. */
export interface QueuedEvent {
  id?: number;
  [k: string]: unknown;
}

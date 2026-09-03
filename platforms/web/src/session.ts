import { monoNow } from './mono-clock';
// Session ID generator + persistence + inactivity timeout.
//
// Tương đương SessionManager bên C++ core (Flutter/iOS/Android): persist
// session_id + session_index qua localStorage để cross-tab, rotate khi user
// idle quá `sessionTimeoutMs`. KHÔNG dùng sessionStorage vì user reload tab
// vẫn cùng session expected.

const KEY_ID = 'unitrack.session_id';
const KEY_IDX = 'unitrack.session_index';
const KEY_PREV = 'unitrack.previous_session_id';
const KEY_LAST_ACTIVE = 'unitrack.session_last_active';
const KEY_STARTED_AT = 'unitrack.session_started_at';

/** Snapshot của phiên vừa đóng. Parity `session_ended` bên iOS/Android. */
export interface ClosedSession {
  id: string;
  durationSec: number;
  screenCount: number;
  hadError: boolean;
  hadCrash: boolean;
  reason: 'timeout' | 'manual';
}

export class SessionManager {
  private timeoutMs: number;
  private currentId: string;
  private currentIndex: number;
  private lastActiveTs: number;
  /** Mốc idle đo bằng đồng hồ đơn điệu — miễn nhiễm với việc chỉnh giờ hệ
   * thống. Chỉ dùng TRONG một lần tải trang: `performance.now()` reset về 0
   * mỗi lần tải, nên khôi phục session qua reload vẫn phải so `Date.now()`. */
  private lastActiveMono: number;
  /** Chế độ ẩn danh 'full': không đọc/ghi localStorage, mỗi lần tải trang là
   * một phiên mới nằm hoàn toàn trong bộ nhớ. */
  private ephemeral: boolean;
  /** Mốc bắt đầu phiên hiện tại — nguồn của `session_duration_sec` khi phiên
   * đóng. Persist để phiên khôi phục qua reload không báo duration ngắn hơn
   * thực tế. */
  private startedAt: number;
  /** Mốc bắt đầu đo bằng đồng hồ đơn điệu, chỉ có giá trị với phiên SINH RA
   * trong lần tải trang này (`performance.now()` reset về 0 mỗi lần tải, nên
   * phiên khôi phục qua reload không dùng được — lúc đó = 0 và duration rơi
   * về `startedAt` wall clock).
   *
   * Tồn tại vì `touch()` quyết định hết hạn bằng đồng hồ đơn điệu: nếu
   * duration lại đo bằng `Date.now()` thì hai bên lệch pha. Máy ngủ 35 phút
   * rồi thức: mono không cộng khoảng ngủ nên phiên vẫn sống, còn wall clock
   * đã nhảy vọt → phiên 33 giây báo thành 2088 giây (đo được trên production
   * 2026-08-22). */
  private startedAtMono: number;
  /** Báo cho SDK biết một phiên vừa đóng, KÈM snapshot của phiên cũ. Gọi
   * trong `rotate()` — id mới đã thay xong, nên snapshot phải chụp trước đó.
   * Parity iOS `emitSessionBoundariesIfNeeded()`. */
  onRotate: ((closed: ClosedSession) => void) | null = null;
  /** Phiên vừa được mở trong constructor (cold start / hết hạn qua reload).
   *  `initialize()` đọc một lần rồi tự xoá, để `session_started` không bắn lại
   *  ở lần khởi tạo kế tiếp trong cùng lần tải trang. */
  freshlyStarted = false;
  /** Đếm cho phiên hiện tại — nuôi `session_ended`. Native lấy các số này từ
   * core; web chưa có core nên SDK tự đếm qua `note*()`. */
  private screenCount = 0;
  private hadError = false;
  private hadCrash = false;

  constructor(timeoutMs = 30 * 60 * 1000, ephemeral = false) {
    this.timeoutMs = timeoutMs;
    this.ephemeral = ephemeral;

    this.lastActiveMono = monoNow();

    if (ephemeral) {
      this.currentId = uuidV4();
      this.currentIndex = 1;
      this.lastActiveTs = Date.now();
      this.startedAt = Date.now();
      this.startedAtMono = monoNow();
      return;
    }

    const storedId = safeGet(KEY_ID);
    const storedIdx = parseInt(safeGet(KEY_IDX) || '0', 10);
    const storedLast = parseInt(safeGet(KEY_LAST_ACTIVE) || '0', 10);
    const now = Date.now();

    // Khôi phục session cũ nếu chưa quá timeout — giữ liền mạch khi user
    // reload page hoặc chuyển tab.
    if (storedId && now - storedLast < this.timeoutMs) {
      this.currentId = storedId;
      this.currentIndex = storedIdx || 1;
      // Reload giữa phiên: giữ mốc bắt đầu cũ, nếu không duration sẽ đếm lại
      // từ 0 mỗi lần F5 và phiên 20 phút báo thành 3 giây.
      this.startedAt = parseInt(safeGet(KEY_STARTED_AT) || '0', 10) || now;
      // Phiên bắt đầu ở lần tải trang TRƯỚC → không có mốc mono so sánh được.
      this.startedAtMono = 0;
    } else {
      // Cold start hoặc đã timeout → rotate.
      // Phiên này dựng THẲNG trong constructor, không đi qua rotate(), nên
      // callback onRotate không chạy và `session_started` không được bắn.
      // Đánh dấu để initialize() bắn bù — nếu không thì phiên MỞ ĐẦU mỗi lần
      // người dùng vào site vĩnh viễn không được đếm, chỉ phiên thứ 2 trở đi
      // mới có. Mobile đếm cả phiên đầu (portal project 8: 28 session_started
      // / 1 session_ended).
      this.freshlyStarted = true;
      if (storedId) safeSet(KEY_PREV, storedId);
      this.currentId = uuidV4();
      this.currentIndex = (storedIdx || 0) + 1;
      safeSet(KEY_ID, this.currentId);
      safeSet(KEY_IDX, String(this.currentIndex));
      this.startedAt = now;
      this.startedAtMono = monoNow();
      safeSet(KEY_STARTED_AT, String(now));
    }
    this.lastActiveTs = now;
    safeSet(KEY_LAST_ACTIVE, String(now));
  }

  currentSessionId(): string { return this.currentId; }
  sessionIndex(): number { return this.currentIndex; }
  previousSessionId(): string { return safeGet(KEY_PREV) || ''; }

  /** SDK gọi khi thấy event tương ứng, để `session_ended` có số thật thay vì
   * số 0 cứng. Gọi TRƯỚC `touch()` không cần thiết — `touch()` xoay phiên thì
   * snapshot đã chụp xong rồi. */
  noteScreen(): void { this.screenCount++; }
  noteError(): void { this.hadError = true; }
  noteCrash(): void { this.hadCrash = true; this.hadError = true; }

  /** App-level event xảy ra → bump last_active. Nếu đã quá timeout từ lần
   * gần nhất → rotate session trước khi return. */
  touch(): void {
    const now = Date.now();
    // Đo thời gian idle bằng performance.now() — đồng hồ ĐƠN ĐIỆU, không bị
    // ảnh hưởng khi hệ điều hành chỉnh giờ. `Date.now()` nhảy tiến (NTP đồng
    // bộ, người dùng sửa giờ, máy thức sau khi ngủ) sẽ bị hiểu nhầm là "đã
    // idle 2 tiếng" → rotate session giữa lúc user đang thao tác; nhảy lùi thì
    // ngược lại, session đáng hết hạn lại sống mãi.
    // Đo được thật: đồng hồ nhảy ±1h làm session_index chạy từ 3 lên 12.
    const mono = monoNow();
    const idle = mono - this.lastActiveMono;
    if (idle >= this.timeoutMs) {
      this.rotate('timeout');
    }
    this.lastActiveMono = mono;
    this.lastActiveTs = now;
    if (!this.ephemeral) safeSet(KEY_LAST_ACTIVE, String(now));
  }

  /** Nối tiếp session từ domain khác (`_sp` trong URL).
   *
   * Ghi đè session vừa dựng: người dùng vốn đang giữa một hành trình, chỉ là
   * đi qua ranh giới domain. Không tăng `session_index` — vẫn là phiên cũ,
   * không phải phiên mới. */
  adopt(sessionId: string): void {
    if (!sessionId || sessionId === this.currentId) return;
    this.currentId = sessionId;
    safeSet(KEY_ID, sessionId);
    safeSet(KEY_LAST_ACTIVE, String(Date.now()));
    this.lastActiveTs = Date.now();
  }

  /** Độ dài phiên hiện tại (giây).
   *
   * Ưu tiên đồng hồ đơn điệu để khớp với thước đo hết hạn của `touch()`;
   * chỉ phiên khôi phục qua reload (`startedAtMono === 0`) mới rơi về wall
   * clock, và ở đó wall clock là lựa chọn ĐÚNG vì mono đã reset. */
  private elapsedSec(): number {
    const ms = this.startedAtMono > 0
      ? monoNow() - this.startedAtMono
      : Date.now() - this.startedAt;
    return Math.max(0, Math.round(ms / 1000));
  }

  /** Force rotate (logout, switch-account, "new conversation" boundary). */
  rotate(reason: 'timeout' | 'manual' = 'manual'): void {
    const prev = this.currentId;
    // Chụp TRƯỚC khi thay id — `session_ended` phải mang id của phiên đóng,
    // không phải phiên vừa mở.
    const closed: ClosedSession = {
      id: prev,
      durationSec: this.elapsedSec(),
      screenCount: this.screenCount,
      hadError: this.hadError,
      hadCrash: this.hadCrash,
      reason,
    };

    this.currentId = uuidV4();
    this.currentIndex += 1;
    this.lastActiveTs = Date.now();
    this.lastActiveMono = monoNow();
    this.startedAt = this.lastActiveTs;
    this.startedAtMono = this.lastActiveMono;
    this.screenCount = 0;
    this.hadError = false;
    this.hadCrash = false;

    if (!this.ephemeral) {           // ẩn danh 'full' → không lưu vết
      safeSet(KEY_PREV, prev);
      safeSet(KEY_ID, this.currentId);
      safeSet(KEY_IDX, String(this.currentIndex));
      safeSet(KEY_LAST_ACTIVE, String(this.lastActiveTs));
      safeSet(KEY_STARTED_AT, String(this.startedAt));
    }

    // Báo sau cùng: callback sẽ track('session_ended'), mà track() gọi
    // touch() — lúc này mốc idle đã reset nên không xoay đệ quy.
    try { this.onRotate?.(closed); } catch { /* callback lỗi không được làm hỏng rotate */ }
  }
}

/** Sinh session_id duy nhất toàn cục.
 *
 * Ba lớp, xuống dần theo mức hỗ trợ của browser:
 *   1. `crypto.randomUUID()` — UUIDv4 chuẩn, 122 bit ngẫu nhiên.
 *   2. `crypto.getRandomValues()` — vẫn cryptographic-grade, tự ghép UUIDv4.
 *   3. `Math.random()` — KHÔNG cryptographic. Chỉ browser rất cũ hoặc trang
 *      không chạy trong secure context (http://) mới rơi vào đây.
 *
 * Ở lớp 3 (và chỉ lớp 3) ghép thêm entropy phi-ngẫu-nhiên: mốc thời gian
 * micro giây + bộ đếm trong tab. Lý do: `Math.random()` giữa hai tab mở cùng
 * lúc có thể cho cùng chuỗi (một số engine seed theo thời gian), còn
 * `performance.timeOrigin + now()` thì khác nhau theo từng tab, và counter
 * bảo đảm hai lần gọi trong cùng một tab không bao giờ giống nhau. */
let localCounter = 0;

function uuidV4(): string {
  const c = typeof crypto !== 'undefined' ? crypto : undefined;

  if (c && typeof c.randomUUID === 'function') {
    return c.randomUUID();
  }

  if (c && typeof c.getRandomValues === 'function') {
    const b = new Uint8Array(16);
    c.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40;   // version 4
    b[8] = (b[8] & 0x3f) | 0x80;   // variant RFC 4122
    const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  // Lớp cuối — trộn thời gian + counter vào để hai tab không đụng nhau.
  const seed = (
    Math.floor((performance?.timeOrigin ?? 0) + (performance?.now?.() ?? Date.now())) * 1000
    + (localCounter++ % 1000)
  ).toString(16).padStart(12, '0').slice(-12);
  const rnd = 'xxxxxxxx-xxxx-4xxx-yxxx'.replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    return (ch === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
  return `${rnd}-${seed}`;
}

function safeGet(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function safeSet(key: string, value: string): void {
  try { localStorage.setItem(key, value); } catch { /* private mode / quota */ }
}

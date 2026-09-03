/** Đồng hồ đơn điệu (ms). Không bao giờ chạy lùi, không bị chỉnh giờ hay đổi
 *  timezone tác động.
 *
 *  Bất biến của SDK: KHÔNG BAO GIỜ gửi khoảng thời gian âm lên wire. Mọi mốc
 *  dùng để trừ ra thời lượng (dwell màn, cửa sổ fg/bg, ttff, watched, duration
 *  của request) phải đi qua đây; `Date.now()` chỉ dành cho timestamp.
 *
 *  Vì sao cần: dwell_ms đo bằng wall clock ra -9.544.502ms trên iPhone thật
 *  (2026-09-02, session 0eeaebfc) khi máy chỉnh giờ lùi 8 tiếng giữa lúc màn
 *  đang mở. Web cũng từng dính cùng lớp lỗi: "phiên 33 giây báo thành 2088
 *  giây" (production 2026-08-22, xem session.ts). */
export function monoNow(): number {
  try {
    return performance.now();
  } catch {
    // Môi trường không có Performance API (worker cũ, jsdom tối giản).
    return Date.now();
  }
}

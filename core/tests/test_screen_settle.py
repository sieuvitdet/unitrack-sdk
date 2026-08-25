#!/usr/bin/env python3
"""Self-check cho settle-window filter (iOS ViewControllerSwizzler +
Android ActivityTracker.afterSettle).

Cả hai platform dùng chung một thuật toán: mỗi lần màn appear/resume thì tăng
một bộ đếm, hoãn việc emit qua cửa sổ settle, rồi chỉ emit nếu bộ đếm CHƯA đổi.
Màn bị màn khác đè lên trong cửa sổ = container trung gian → bỏ.

Chạy: python3 core/tests/test_screen_settle.py
"""

SETTLE_MS = 50


class SettleFilter:
    """Bản Python 1:1 của afterSettle (Kotlin) / closure guard (Swift)."""

    def __init__(self, settle_ms=SETTLE_MS):
        self.settle_ms = settle_ms
        self.seq = 0
        self.pending = []   # (fire_at_ms, my_seq, screen)
        self.emitted = []
        self.last_screen = None

    def on_appear(self, screen, now_ms):
        self.seq += 1
        if self.settle_ms <= 0:          # 0 = tắt lọc, emit thẳng
            self._emit(screen)
            return
        self.pending.append((now_ms + self.settle_ms, self.seq, screen))

    def _emit(self, screen):
        """Dup guard của setScreen: cùng screen 2 lần liên tiếp không phải
        boundary thật → screen_load_completed bị bỏ. Bản Python của
        `isSameScreen` (Swift) / `setScreenReportingDup` (Kotlin)."""
        if screen == self.last_screen:
            return                       # VC dựng lại cho màn đang mở
        self.last_screen = screen
        self.emitted.append(screen)

    def on_screen_end(self):
        """screen_end đóng màn → lần vào sau là boundary thật kể cả trùng tên."""
        self.last_screen = None

    def tick(self, now_ms):
        """Chạy các closure đã tới hạn."""
        still = []
        for fire_at, my_seq, screen in self.pending:
            if fire_at > now_ms:
                still.append((fire_at, my_seq, screen))
            elif my_seq == self.seq:     # guard: chưa ai đè lên
                self._emit(screen)
        self.pending = still


def run(events, settle_ms=SETTLE_MS, end_ms=200_000):
    """events = [(t_ms, screen)] → danh sách screen thực sự được emit.
    screen = None nghĩa là screen_end (màn đóng lại)."""
    f = SettleFilter(settle_ms)
    for t, screen in events:
        f.tick(t)
        if screen is None:
            f.on_screen_end()
        else:
            f.on_appear(screen, t)
    f.tick(end_ms)
    return f.emitted


def test_container_burst_is_filtered():
    """Cảnh thật của session d36eaf25: 4 VC appear trong 12ms, chỉ VC cuối
    là màn người dùng thấy."""
    got = run([
        (8732, "FSSHomeTabBarViewController"),
        (8736, "MainHomeViewController"),
        (8740, "AppTabBarPagerController"),
        (8744, "HomeAllDeviceViewController"),
    ])
    assert got == ["HomeAllDeviceViewController"], got


def test_real_navigation_survives():
    """Người dùng chuyển màn bình thường (cách nhau > settle) → giữ đủ."""
    got = run([
        (0,    "HomeViewController"),
        (3000, "DetailViewController"),
        (9000, "ProfileViewController"),
    ])
    assert got == ["HomeViewController",
                   "DetailViewController",
                   "ProfileViewController"], got


def test_boundary_exactly_at_window():
    """Đúng bằng cửa sổ thì màn trước ĐƯỢC giữ — closure của nó chạy trước
    khi màn sau kịp tăng seq. Đây là ranh giới: chậm hơn 50ms là màn thật."""
    got = run([(0, "A"), (SETTLE_MS, "B")])
    assert got == ["A", "B"], got


def test_just_inside_window_is_dropped():
    """Sớm hơn cửa sổ 1ms → A bị coi là container."""
    got = run([(0, "A"), (SETTLE_MS - 1, "B")])
    assert got == ["B"], got


def test_flash_screen_then_home():
    """Màn flash sống 6.35s rồi mới sang home → cả hai đều là màn thật."""
    got = run([(0, "ISCFlashScreen"), (6350, "HomeAllDevice")])
    assert got == ["ISCFlashScreen", "HomeAllDevice"], got


def test_settle_zero_disables_filter():
    """screen_settle_ms = 0 → tắt lọc, giữ nguyên hành vi cũ."""
    got = run([(0, "A"), (1, "B"), (2, "C")], settle_ms=0)
    assert got == ["A", "B", "C"], got


def test_single_screen_still_emits():
    """Chỉ một màn, không ai đè → vẫn phải bắn (regression: guard quá tay)."""
    assert run([(0, "OnlyScreen")]) == ["OnlyScreen"]


def test_full_session_replay():
    """Replay session d36eaf25 (mốc ms thật từ VPS, TRƯỚC fix).
    10 lần appear → chỉ còn màn người dùng thật sự nhìn thấy.

    HomeAllDevice chỉ còn MỘT lần: các lần sau là VC dựng lại cho chính màn
    đang mở (không có screen_end xen giữa) nên dup guard nuốt."""
    got = run([
        (1486, "ISCFlashScreenSyncDataViewController"),
        (7837, None),                       # screen_end ISCFlashScreen (fg=6.35)
        (7842, "HomeAllDeviceViewController"),
        (8732, "FSSHomeTabBarViewController"),
        (8736, "MainHomeViewController"),
        (8740, "AppTabBarPagerController"),
        (8744, "HomeAllDeviceViewController"),
        (8946, "FSSHomeTabBarViewController"),
        (8950, "MainHomeViewController"),
        (8955, "AppTabBarPagerController"),
        (8958, "HomeAllDeviceViewController"),
    ])
    assert got == ["ISCFlashScreenSyncDataViewController",
                   "HomeAllDeviceViewController"], got


def test_vc_rebuilt_for_open_screen_is_dropped():
    """Session 496552f3 lúc 11:27: FPT Life dựng tab "all" lúc layout rồi dựng
    LẠI khi API items về (FSSHomeViewController.swift dòng 60 và 165).
    Hai instance, cách nhau 1.45s, KHÔNG có screen_end ở giữa → người dùng
    thấy một màn liên tục nên chỉ tính một load."""
    got = run([
        (61999, "CameraHomeViewController"),   # instance #1, load=29
        (63452, "CameraHomeViewController"),   # instance #2, load=2 — bỏ
    ])
    assert got == ["CameraHomeViewController"], got


def test_revisit_after_screen_end_still_counts():
    """Ngược lại: rời màn (có screen_end) rồi quay lại CÙNG màn là lần vào
    thật — phải giữ. Đây là ranh giới phân biệt với case trên."""
    got = run([
        (0,     "HomeViewController"),
        (5000,  None),                      # screen_end — rời màn thật
        (5010,  "DetailViewController"),
        (9000,  None),
        (9010,  "HomeViewController"),      # quay lại → boundary thật
    ])
    assert got == ["HomeViewController",
                   "DetailViewController",
                   "HomeViewController"], got


def test_session_11h26_end_to_end():
    """Replay đủ session 496552f3 (11:26:06 → 11:27:45), build ĐÃ có fix
    container. 12 event gốc → 3 màn thật, 2 VC-dựng-lại bị bỏ."""
    got = run([
        (0,     "ISCFlashScreenSyncDataViewController"),
        (5857,  None),                          # fg=5.86
        (5859,  "HomeAllDeviceViewController"),
        (37143, "HomeAllDeviceViewController"), # dựng lại sau 31s — bỏ
        (61233, None),                          # fg=55.37
        (61241, "CameraHomeViewController"),
        (62694, "CameraHomeViewController"),    # dựng lại sau 1.45s — bỏ
    ])
    assert got == ["ISCFlashScreenSyncDataViewController",
                   "HomeAllDeviceViewController",
                   "CameraHomeViewController"], got


# ── load_ms: mốc đo cho VC được giữ lại ────────────────────────────────────
# iOS: viewDidLoad đặt mốc, viewWillAppear RE-ARM nếu VC đã từng hiện.
# Android: onCreate đặt mốc, onStart re-arm. Cùng một luật.

class LoadTimer:
    """Bản Python của ut_loadStart / ut_loadReported (Swift) và
    activityCreatedAtMs / activityLoadReported (Kotlin)."""

    def __init__(self):
        self.start = None
        self.reported = False

    def did_load(self, now):          # viewDidLoad / onCreate
        self.start = now

    def will_appear(self, now):       # viewWillAppear / onStart
        # Lần đầu KHÔNG đụng: sẽ nuốt mất phần dựng view cần đo.
        if self.reported:
            self.start = now

    def did_appear(self, now):        # viewDidAppear / onResume
        if self.start is None:
            return None
        self.reported = True
        return now - self.start


def test_load_ms_first_appearance_measures_build_cost():
    """Lần đầu: viewWillAppear không được ghi đè mốc, nếu không load_ms = 0
    và ta mất chính con số cần đo."""
    t = LoadTimer()
    t.did_load(1000)
    t.will_appear(1005)    # ngay sau viewDidLoad
    assert t.did_appear(1014) == 14


def test_load_ms_kept_vc_does_not_accumulate_idle():
    """Bug thật của session 6fda62c3: CameraHomeViewController dựng ở +10098ms,
    người dùng rời đi xem live 85 giây rồi quay lại → báo load=85764.
    Sau fix, mốc được re-arm ở viewWillAppear nên chỉ đo lần hiện lại."""
    t = LoadTimer()
    t.did_load(10098)
    t.will_appear(10100)
    assert t.did_appear(10112) == 14        # lần đầu: 14ms

    # 85 giây sau, VC vẫn sống, viewDidLoad KHÔNG chạy lại
    t.will_appear(95850)                     # re-arm vì đã reported
    got = t.did_appear(95862)
    assert got == 12, got                    # không phải 85764


def test_load_ms_revisit_still_reports():
    """Android trước fix dùng remove() nên lần quay lại mất hẳn load_ms.
    Sau fix phải có số, không được None."""
    t = LoadTimer()
    t.did_load(0); t.will_appear(0)
    assert t.did_appear(30) == 30
    t.will_appear(5000)
    assert t.did_appear(5008) == 8           # không None


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"  PASS  {t.__name__}")
    print(f"\n{len(tests)} passed")

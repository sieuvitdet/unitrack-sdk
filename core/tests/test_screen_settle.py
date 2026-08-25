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

    def on_appear(self, screen, now_ms):
        self.seq += 1
        if self.settle_ms <= 0:          # 0 = tắt lọc, emit thẳng
            self.emitted.append(screen)
            return
        self.pending.append((now_ms + self.settle_ms, self.seq, screen))

    def tick(self, now_ms):
        """Chạy các closure đã tới hạn."""
        still = []
        for fire_at, my_seq, screen in self.pending:
            if fire_at > now_ms:
                still.append((fire_at, my_seq, screen))
            elif my_seq == self.seq:     # guard: chưa ai đè lên
                self.emitted.append(screen)
        self.pending = still


def run(events, settle_ms=SETTLE_MS, end_ms=10_000):
    """events = [(t_ms, screen)] → danh sách screen thực sự được emit."""
    f = SettleFilter(settle_ms)
    for t, screen in events:
        f.tick(t)
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
    """Replay toàn bộ session d36eaf25 (mốc ms thật từ VPS).
    28 event gốc → chỉ còn các màn người dùng thật sự nhìn thấy."""
    got = run([
        (1486, "ISCFlashScreenSyncDataViewController"),
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
    # 10 lần appear → 4 màn thật, 6 container bị lọc.
    # HomeAllDevice xuất hiện 3 lần vì mỗi lần nó sống > 50ms (890ms, 202ms,
    # tới hết session) — đúng với dữ liệu VPS: fg=0.89 và fg=0.2. Các
    # container xen giữa (fg=0) mới là thứ bị loại.
    assert got == ["ISCFlashScreenSyncDataViewController",
                   "HomeAllDeviceViewController",
                   "HomeAllDeviceViewController",
                   "HomeAllDeviceViewController"], got


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"  PASS  {t.__name__}")
    print(f"\n{len(tests)} passed")

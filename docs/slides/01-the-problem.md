---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 01/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Vấn đề: phân tích đang **manual hoá**

Mỗi app FPT Telecom (Life / Camera / MobiNet / MobiX) tự viết wrapper
Snowplow + Firebase riêng. **FPT Life** là ví dụ điển hình.

---

## FPTLife/FLifeTracker hiện tại

```
FLifeTracker/
├── FLifeTracker.swift               149 dòng  — enums hardcode
├── SnowplowService.swift            129 dòng  — direct Snowplow
└── FirebaseAnalyticsService.swift    58 dòng  — direct Firebase
```

Mỗi event mới → dev sửa **5 chỗ** + ship app store:

1. Case mới ở `FLifeTrackEvent` + `ButtonLabel` + `ScreenName` enum
2. Hardcode schema URI `SnowplowSchema.buttonClick = "iglu:.../button_click/..."`
3. Switch case ở `SnowplowAnalyticsProvider`
4. Switch case ở `FirebaseAnalyticsProvider`
5. Gọi `AnalyticsManager.shared.track(.buttonClick(...), target: .behavior)` ở UI

---

## Các thiếu sót cụ thể

| Thiếu | Hệ quả |
|---|---|
| Không auto-capture | Mỗi button mới → 1 PR; quên gọi → mất data |
| Schema cứng trong code | Đổi tên event = build + ship app store |
| Không offline queue | Mất mạng = mất event |
| Crash không recover | App crash xong = mất context lần mở sau |
| Không session reconstruction | Backend nhận event rời, không biết user đi qua màn nào |
| Không có portal | Xem event = Snowplow Console (external) hoặc Firebase (delay 24h) |
| Không HTTP correlation | API fail không gắn được với button user vừa bấm |
| Provider tách rời | Viết 2 lần cùng 1 logic cho Snowplow + Firebase |

---

## Quy mô vấn đề

Mỗi feature mới ~20-30 sự kiện tracking.

**Hiện trạng / quarter:**

```
~20 PR  ×  ~5 file/PR  ×  2 reviewer  ≈  200 review-hours
```

Toàn bộ chỉ để **wire boilerplate analytics**, không phải để
**phân tích data**.

---

## Vì sao cần SDK chung

Không chỉ FPT Life:

- FPT Camera B2C
- MobiX Maintenance
- MobiNet Customer
- Internal tools

Mỗi team **tự maintain** cùng một lớp wrapper Snowplow/Firebase.

> **UniTrack thay tất cả: 1 SDK + 1 portal cho mọi project.**

→ Slide tiếp: [02 — Tầm nhìn](02-the-vision.md)

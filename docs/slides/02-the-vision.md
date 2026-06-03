---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 02/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Tầm nhìn: **3 dòng code = 30 events**

App tích hợp UniTrack chỉ cần:

```swift
UniTrack.initialize(apiKey: "utk_…")     // 1 dòng → init SDK + 4 provider
UniTrack.addProvider(SnowplowProvider()) // 2 dòng → Snowplow tự fan-out
UniTrack.addProvider(FirebaseProvider()) // 3 dòng → Firebase + portal mirror
```

Sau đó: **không viết thêm code tracking nào** cho:

- Mọi button tap → `event_click` với element_key + screen + class
- Mọi screen navigate → `screen_view` với load_ms
- Mọi HTTP request → `event_api` với url + status + duration
- App lifecycle → `app_start` / `app_foreground` / `app_background`
- App crash → `event_crash` recover ở lần mở sau (signal handler)
- App memory warning → `memory_warning` với threshold

---

## Architecture đảo ngược so với FLifeTracker

**FLifeTracker** (current):
```
App code ─→ define enum ─→ define schema ─→ track(.case) ─→ provider
                                                              ↓
                                                            Snowplow
                                                              ↓
                                                            Firebase
```

**UniTrack:**
```
App code ─→ UniTrack.track(...) ─→ convention layer ─→ all providers
                                          ↑
                                          │
                                  portal remote_config
                                  (event_names, schemas)
```

→ **Đổi tên event = sửa portal, không build app.**

---

## 4 platform, 1 SDK, 1 API

| Platform | Tích hợp | Auto-capture | Convention helpers |
|---|---|---|---|
| **iOS Swift** | SPM / CocoaPods | UIControl swizzle | trackingClickEvent / Result / API / Crash / Session |
| **Android Kotlin** | JitPack / Maven | View.OnClickListener wrap | cùng helpers |
| **Flutter Dart** | pub path | GestureDetector listener | cùng helpers |
| **React Native** | npm path | Pressable HOC | cùng helpers |

Mã shared 70%: C++ core (offline queue, session, transport, crash) ở `core/`.

---

## Lợi ích đo lường được

| Trước (FLifeTracker) | Sau (UniTrack) | Improve |
|---|---|---|
| 5 file sửa / event mới | 0 file | ∞ |
| Build + ship để đổi tên | Edit portal | 24h → 0min |
| Manual fire tap | Auto-capture | 100% coverage |
| Mất event khi offline | Offline queue + retry | 0 mất |
| Crash → mất context | Recover next launch | 100% |
| Snowplow + Firebase + portal | All 3 in 1 init | 3 SDK → 1 |
| 200 review-hours/quarter | <20h | -90% |

---

## Demo trực tiếp

Trong test session gần nhất:

```
RN demo:    1 click button → fire qua convention → 3 providers
Flutter:    Fire ALL test → 28 events → portal nhận đủ trong 3s
Android:    Crash recovery → JSON + signal + recovered_on_launch
iOS:        Convention layer → schema URI auto-build từ vendor
```

Tất cả không cần thêm code, chỉ cấu hình portal.

→ Slide tiếp: [03 — Architecture](03-architecture.md)

---
marp: true
theme: default
paginate: true
header: 'UniTrack · slide 10/10'
footer: 'Tích hợp UniTrack vào FPT Life'
---

# Roadmap: cần cải thiện gì tiếp

## Đã làm (Phase 1-3)

- ✅ Core C++ offline queue + crash handler + session manager
- ✅ 4 platform binding (iOS / Android / Flutter / RN)
- ✅ Auto-capture click + screen + network + crash + lifecycle
- ✅ Convention layer 6 kinds (click/result/screen_view/crash/api/session)
- ✅ Snowplow provider 3 platform (iOS / Android / Flutter)
- ✅ Firebase provider 2 platform (iOS / Android)
- ✅ Remote config (sdk_config + Snowplow + Firebase + tracing)
- ✅ Export/Import config JSON bundle
- ✅ Portal session IDE + sp_event_maps forwarder
- ✅ JitPack publish Android; SwiftPackage push tag iOS
- ✅ W3C Trace Context (traceparent injection)
- ✅ Demo apps 4 platform với 30-event sheet taxonomy

---

## Cần cải thiện ngắn hạn (Q1 2026)

| Hạng mục | Status | Lý do |
|---|---|---|
| **Snowplow provider cho RN** | ✅ ready | `@unitrack/snowplow` package — 6 convention helper + 3 entity auto-attach, parity iOS/Android; wrap `@snowplow/react-native-tracker` |
| **Firebase provider cho Flutter** | ✅ ready | `unitrack_firebase` Dart hoàn chỉnh, `flutter analyze` xanh, README hướng dẫn google-services.json + plist setup |
| **iOS native session_ended callback** | ✅ | `AppLifecycleObserver` fire `session_ended` với duration + screen_count khi foreground sau timeout (SwiftPackage 0.3.7) |
| **Screen wireframe capture** | ⚠️ parked | Code có (`UniTrackWireframe.swift`) nhưng OOM trên Flutter; cần optimize |
| **Per-event verbose log RN** | ❌ | iOS/Android có; RN chỉ log HTTP POST size — khó debug |
| **Unit tests coverage** | ⚠️ <30% | Core C++ test tốt; binding chưa nhiều |
| **API documentation** | ⚠️ | Mới có slide; cần API reference auto-gen (DocC / KDoc / dartdoc / TypeDoc) |

---

## Cần cải thiện trung hạn (Q2-Q3 2026)

| Hạng mục | Mô tả |
|---|---|
| **Heatmap UI portal** | Aggregate element_key + class_name → render lên screenshot |
| **Session replay** | Record + playback video screen (như Hotjar) — heavy bandwidth |
| **Funnel builder UI** | Drag-drop event_name → tự gen SQL funnel + drop-off rate |
| **A/B test framework** | flavor đã có, cần UI để split traffic + đo metric |
| **GDPR consent gating** | SDK respect consent flag, không fire event nếu user opt-out |
| **Distributed tracing end-to-end** | App `traceparent` → backend nginx log → portal correlate |
| **Push notification analytics deeper** | iOS UNNotificationServiceExtension capture, Android FCM Service direct hook |
| **WebView auto-capture** | iOS có swizzle WKWebView; cần Android + Flutter parity |

---

## Cần cải thiện dài hạn (Q4 2026+)

| Hạng mục | Mô tả |
|---|---|
| **AI Agent insights** | LLM đọc session journey → flag "user bị stuck ở pairing 3 lần" |
| **Anomaly detection** | Statistical baseline → alert khi event volume drop 50% sudden |
| **Cohort analysis** | User segmentation by event behavior |
| **Multi-tenant portal** | 1 portal cho nhiều org (FPT Tel, FPT Software, customer ngoài) |
| **Open-source publish** | Apache 2.0 license, GitHub public + Maven Central + CocoaPods Trunk |
| **SDK size optimization** | Strip C++ exceptions, link sqlite tĩnh, AAR <100KB |
| **iOS App Clip support** | SDK init lightweight cho App Clip 10MB budget |

---

## Câu hỏi mở

1. **Nên duy trì 6 generic schema hay mở rộng theo nhu cầu team?**
   - Pro 6: Iglu Registry gọn, không cần update mỗi event mới
   - Con 6: dùng `event_name` field thay schema có thể khó query trên Snowplow downstream

2. **Có nên migrate Snowplow direct → portal forward?**
   - App chỉ gọi UniTrack, portal route sang Snowplow
   - Pro: app SDK nhẹ hơn (bỏ Snowplow tracker plugin); centralize logic
   - Con: portal trở thành SPOF

3. **Crash symbolication ở client hay server?**
   - Hiện tại: frames là raw address; portal cần dSYM/proguard map để symbolicate
   - Alternative: app upload dSYM lên portal khi release build

→ Hết slide. Câu hỏi → xem [Q&A.md](Q&A.md)

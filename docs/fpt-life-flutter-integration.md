# FPT Life Flutter module — Tích hợp UniTrack auto-capture

## Tình trạng hiện tại

App FPT Life iOS (repo `FPT-Life-FLI`) nhúng Flutter qua `App.xcframework` build sẵn từ 1 repo Flutter source RIÊNG. Khi user dùng:

- **UIKit screens** (Home, Camera, Pairing…) → ✅ Native UniTrack swizzler auto-capture tap + screen
- **Flutter screens** (route trong `AppFlutterViewController`) → ❌ **0 event tap**, screen chỉ có nếu DEV manual gọi

Lý do kỹ thuật:
- Flutter render canvas riêng → mỗi tap được hit-test trong Dart widget tree, không sinh ra `UIControl.sendActions` hay `UITapGestureRecognizer` riêng biệt để native swizzler bắt
- Native swizzler (đúng đắn) yield boundary `FlutterViewController` để Flutter SDK tự handle subtree (xem `ViewControllerSwizzler.swift:ut_yieldToCrossPlatformLayer`)

## Việc cần làm — Bên Flutter module

### Bước 1: Add dependency

`pubspec.yaml`:

```yaml
dependencies:
  unitrack: ^1.2.1   # https://pub.dev/packages/unitrack
```

Chạy:
```bash
flutter pub get
```

### Bước 2: Bootstrap trong main.dart

```dart
import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // KHÔNG cần gọi UniTrack.initialize() — native iOS đã init rồi
  // (FSDKTracking.bootstrap() bên Swift). Flutter side chỉ piggyback
  // qua MethodChannel để dùng cùng C core + session_id.

  // Bắt buộc: register layer để native swizzler biết Flutter có mặt
  // và yield subtree khi user push Flutter route
  await UniTrackLayerRegistry.register(UniTrackLayer.flutter);

  runApp(
    UniTrackTapObserver(                       // ← wrap toàn app
      child: MaterialApp(
        navigatorObservers: [
          UniTrackRouteObserver(),             // ← screen tracking
        ],
        home: MyHomePage(),
      ),
    ),
  );
}
```

### Bước 3: Rebuild App.xcframework

DEV Flutter chạy:
```bash
flutter build ios-framework \
  --output=build/ios-framework \
  --no-debug --no-profile
```

Copy `build/ios-framework/Release/App.xcframework` về `FPT-Life-FLI/FPTLife/FSS/Libs/Flutter/` thay file cũ.

### Bước 4: Verify trên Portal

Sau khi rebuild app FPT Life iOS:

1. User tap button BÊN TRONG Flutter screen → Portal pid=8 → tab Events thấy:
   - `screen_view` với `screen=/route-name` (Dart route name) 
   - `click` với `element_key=...` (resolved từ widget key/text)
   - `framework=flutter`

2. User navigate native → Flutter:
   - Native fire `screen_view screen=AppFlutterViewController` 
   - Dart fire `screen_view screen=/route-name`
   - Layer registry + dedup 250ms suppress duplicate, GIỮ Dart event (subtree claim)
   - Portal CHỈ thấy 1 event `screen_view` per transition

## Nếu DEV Flutter không muốn add full unitrack Dart

Option B — chỉ wire **manual track 1 dòng** mỗi widget quan trọng:

```dart
import 'package:flutter/services.dart';

const _channel = MethodChannel('unitrack');

void track(String event, Map<String, dynamic> props) {
  _channel.invokeMethod('track', {'event': event, 'properties': props});
}

// Trong onPressed:
ElevatedButton(
  onPressed: () {
    track('click', {
      'element_key': 'cta_buy',
      'screen': '/home',
      'framework': 'flutter',
    });
    onBuy();
  },
  child: Text('Buy'),
)
```

→ Không auto-capture, nhưng zero deps; mỗi tap quan trọng DEV thêm 4 dòng. Phù hợp nếu Flutter module FPT Life chỉ có 5-10 màn cần track.

## Câu hỏi thường gặp

**Q: Flutter SDK + Native SDK cùng init có conflict không?**
A: Không. C core là singleton trong process. `UniTrackLayerRegistry.register` chỉ ghi bitmask. `UniTrack.initialize()` ở Dart side là no-op nếu native đã init.

**Q: Sao không inject UniTrack Dart vào App.xcframework từ phía iOS?**
A: Bất khả — Flutter compile Dart thành snapshot AOT trong xcframework. Phải sửa source Dart + rebuild.

**Q: Có cách nào auto-detect tap từ FlutterView qua iOS không?**
A: Có thể intercept `FlutterView.hitTest` qua swizzling, nhưng:
- Chỉ thấy point (x,y) raw, không biết widget nào
- Flutter team không guarantee `FlutterView` internals
- Đã thử trong Sentry/Firebase: bỏ giữa chừng vì fragile

**Q: Repo Flutter module FPT Life ở đâu?**
A: Cần hỏi DEV Flutter FPT Life. Workspace iOS hiện tại chỉ có binary `App.xcframework`.

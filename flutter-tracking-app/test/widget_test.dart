// Smoke test: the app boots to the Login screen.
//
// Note: main() initializes the UniTrack MethodChannel, which has no native
// binding under the test harness — so we pump MobixDemoApp directly rather
// than calling main().

import 'package:flutter_test/flutter_test.dart';
import 'package:mobix_tracking_demo/main.dart';

void main() {
  testWidgets('App boots to login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MobixDemoApp());
    await tester.pump();
    expect(find.text('Mobix Tracking Demo'), findsOneWidget);
    expect(find.text('Đăng nhập'), findsOneWidget);
  });
}

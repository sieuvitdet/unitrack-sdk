// Settings — plain UI. The only SDK calls here are legitimate runtime controls
// (enable/disable tracking) and a deliberate crash to demo the native crash
// handler — not per-event tracking, which is fully automatic.

import 'package:flutter/material.dart';
import 'package:unitrack/unitrack.dart';

class SettingsScreen extends StatefulWidget {
  static const route = '/settings';
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _trackingEnabled = true;
  bool _notifications = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Bật tracking'),
            subtitle: const Text('UniTrack.setEnabled()'),
            value: _trackingEnabled,
            onChanged: (v) {
              setState(() => _trackingEnabled = v);
              UniTrack.instance.setEnabled(v);
            },
          ),
          SwitchListTile(
            title: const Text('Thông báo'),
            value: _notifications,
            onChanged: (v) => setState(() => _notifications = v),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('NOTIFICATION (3 trạng thái)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          // Uses the drop-in captureNotification(): state is derived from app
          // lifecycle + whether there is visible content. Here we force the
          // three cases so you can verify each on the portal.
          ListTile(
            leading: const Icon(Icons.notifications_active, color: Colors.blue),
            title: const Text('Notification foreground'),
            subtitle: const Text("state ⇒ 'foreground'"),
            onTap: () => UniTrack.instance.captureNotification(
                hasVisibleContent: true,
                title: 'Khuyến mãi',
                body: 'Giảm 50% hôm nay'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications, color: Colors.grey),
            title: const Text('Notification opened (từ background)'),
            subtitle: const Text("action ⇒ 'opened'"),
            onTap: () => UniTrack.instance.trackNotification(
                state: 'background', action: 'opened', title: 'Đơn hàng #1234'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_off, color: Colors.purple),
            title: const Text('Silent notification (data-only)'),
            subtitle: const Text("state ⇒ 'silent'"),
            onTap: () => UniTrack.instance.captureNotification(
                hasVisibleContent: false, data: {'sync': 'inventory'}),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.web),
            title: const Text('Mở WebView'),
            onTap: () => UniTrack.instance
                .trackWebViewOpen('https://mobix.asia/promo?ref=app'),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Giả lập deeplink'),
            onTap: () => UniTrack.instance
                .trackDeeplink('mobixapp://product/123', source: 'demo'),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Mở app bên thứ 3 (MoMo)'),
            onTap: () => UniTrack.instance.trackThirdPartyOpen('momo_payment'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.red),
            title: const Text('Gây lỗi Dart (sync)',
                style: TextStyle(color: Colors.red)),
            subtitle: const Text('FlutterError.onError → crash event'),
            // Throwing inside a build/callback is caught by FlutterError.onError,
            // which the SDK hooks and reports as a `crash` event.
            onTap: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                throw StateError('Intentional sync crash from Settings');
              });
            },
          ),
          ListTile(
            leading: const Icon(Icons.bolt, color: Colors.red),
            title: const Text('Gây lỗi async (uncaught)',
                style: TextStyle(color: Colors.red)),
            subtitle: const Text('PlatformDispatcher.onError → crash event'),
            // An uncaught async error reaches PlatformDispatcher.onError, also
            // hooked by the SDK. (Requires main() to runApp in the same zone.)
            onTap: () {
              Future<void>.delayed(const Duration(milliseconds: 50), () {
                throw StateError('Intentional async crash from Settings');
              });
            },
          ),
        ],
      ),
    );
  }
}

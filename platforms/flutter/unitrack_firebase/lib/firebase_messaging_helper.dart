// UniTrackFirebaseMessaging — push/notification + FCM token tracking helpers.
//
// Apps already own their FirebaseMessaging callbacks (token rotation handler,
// onMessage / onMessageOpenedApp listeners). This helper does NOT take over
// those callbacks — instead the app calls one method per callback site and
// gets:
//
//   • fcm_token_updated event (deduped against previous token)
//   • notification event with state=foreground/background/silent + action
//     received/clicked, routed through UniTrack.trackNotification so the
//     portal + Snowplow + Firebase Analytics all see the same notification.
//
// Wire-up (typical app):
//
//   FirebaseMessaging.instance.onTokenRefresh.listen(
//     UniTrackFirebaseMessaging.handleTokenUpdate);
//
//   FirebaseMessaging.onMessage.listen(
//     UniTrackFirebaseMessaging.handleNotificationReceivedForeground);
//
//   FirebaseMessaging.onMessageOpenedApp.listen(
//     UniTrackFirebaseMessaging.handleNotificationClicked);
//
//   final initialMsg = await FirebaseMessaging.instance.getInitialMessage();
//   if (initialMsg != null) {
//     UniTrackFirebaseMessaging.handleNotificationClicked(initialMsg);
//   }

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:unitrack/unitrack.dart';

class UniTrackFirebaseMessaging {
  UniTrackFirebaseMessaging._();

  static String? _cachedToken;

  /// Latest FCM token seen by the helper (null until [handleTokenUpdate]
  /// has been called at least once).
  static String? get currentToken => _cachedToken;

  /// Wire to `FirebaseMessaging.instance.onTokenRefresh` AND the value from
  /// `getToken()` at startup. Fires `fcm_token_updated` only when the token
  /// actually changes — Firebase re-emits the same token on every cold start
  /// and we don't want to spam analytics with duplicates.
  static void handleTokenUpdate(String? token) {
    final prev = _cachedToken;
    _cachedToken = token;
    if (token == null || token.isEmpty || token == prev) return;
    final props = <String, Object?>{'fcm_token': token};
    if (prev != null && prev.isNotEmpty) props['prev_token'] = prev;
    UniTrack.instance.track('fcm_token_updated', properties: props);
  }

  /// Wire to `FirebaseMessaging.onMessage`. Fires when a push lands while the
  /// app is in the foreground (iOS calls willPresent → app gets a chance to
  /// display; Android delivers to onMessage directly).
  static void handleNotificationReceivedForeground(RemoteMessage message) {
    UniTrack.instance.trackNotification(
      state: 'foreground',
      action: 'received',
      title: message.notification?.title,
      body:  message.notification?.body,
      notificationId: _idOf(message),
      data: _safeData(message.data),
    );
  }

  /// Wire to `FirebaseMessaging.onMessageOpenedApp` AND
  /// `FirebaseMessaging.instance.getInitialMessage()` (which fires when the
  /// app launched from a tapped push). Treated as the moment the user
  /// actually engaged.
  static void handleNotificationClicked(RemoteMessage message) {
    UniTrack.instance.trackNotification(
      state: 'foreground',
      action: 'clicked',
      title: message.notification?.title,
      body:  message.notification?.body,
      notificationId: _idOf(message),
      data: _safeData(message.data),
    );
  }

  /// Wire to your background message handler (the `@pragma('vm:entry-point')`
  /// top-level function passed to `FirebaseMessaging.onBackgroundMessage`).
  /// Treated as a silent / background-arrival event.
  ///
  /// Note: background handlers run in an isolated Dart isolate; the UniTrack
  /// instance there has NO active session unless the app initializes it
  /// inside the entry-point. The event will still queue locally and flush
  /// once the main isolate revives.
  static void handleBackgroundMessage(RemoteMessage message) {
    final hasVisible = message.notification != null;
    UniTrack.instance.trackNotification(
      state: hasVisible ? 'background' : 'silent',
      action: 'received',
      title: message.notification?.title,
      body:  message.notification?.body,
      notificationId: _idOf(message),
      data: _safeData(message.data),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────

  // FCM messageId is the canonical id when present; on iOS the same id is
  // mirrored under `gcm.message_id` / `google.message_id` in the data bag.
  // Fall back to those for parity with the Swift implementation.
  static String? _idOf(RemoteMessage m) {
    if (m.messageId != null && m.messageId!.isNotEmpty) return m.messageId;
    final d = m.data;
    final g = d['gcm.message_id'] ?? d['google.message_id'];
    if (g is String && g.isNotEmpty) return g;
    return null;
  }

  // RemoteMessage.data is already Map<String,String>, but be defensive in
  // case future Firebase versions widen the value type.
  static Map<String, Object?> _safeData(Map<String, dynamic> data) {
    if (data.isEmpty) return const <String, Object?>{};
    final out = <String, Object?>{};
    data.forEach((k, v) {
      if (v is String || v is num || v is bool || v == null) out[k] = v;
      else out[k] = v.toString();
    });
    return out;
  }
}

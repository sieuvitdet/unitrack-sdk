// UniTrackFirebaseMessaging — push / FCM helpers.
//
// Apps own their FirebaseMessaging callbacks; this helper does NOT replace
// them. Call one method per callback site and you get:
//   • fcm_token_updated event (deduped against previous token)
//   • notification event with state foreground/background/silent + action
//     received/clicked, routed through UniTrack.trackNotification
//
//   import messaging from '@react-native-firebase/messaging';
//   import { UniTrackFirebaseMessaging } from '@unitrack/firebase';
//
//   messaging().onTokenRefresh(UniTrackFirebaseMessaging.handleTokenUpdate);
//   messaging().onMessage(UniTrackFirebaseMessaging.handleNotificationReceivedForeground);
//   messaging().onNotificationOpenedApp(UniTrackFirebaseMessaging.handleNotificationClicked);
//   const initial = await messaging().getInitialMessage();
//   if (initial) UniTrackFirebaseMessaging.handleNotificationClicked(initial);

import UniTrack from '@unitrack/react-native';

// Minimal subset of @react-native-firebase/messaging's RemoteMessage type.
// We don't import the real type to keep this helper compile-able even when
// the host app hasn't installed the messaging module (peerDependenciesMeta).
interface RemoteMessageLite {
  messageId?: string;
  notification?: { title?: string; body?: string };
  data?: Record<string, string | number | boolean>;
}

export class UniTrackFirebaseMessaging {
  private static cachedToken: string | null = null;

  /** Latest FCM token observed by the helper. */
  static get currentToken(): string | null {
    return UniTrackFirebaseMessaging.cachedToken;
  }

  /** Wire to `messaging().onTokenRefresh(...)` AND `getToken()` at startup.
   *  Fires `fcm_token_updated` only when the token actually changes — FCM
   *  re-emits the same token every cold start. */
  static handleTokenUpdate(token: string | null | undefined): void {
    const prev = UniTrackFirebaseMessaging.cachedToken;
    UniTrackFirebaseMessaging.cachedToken = token ?? null;
    if (!token || token === prev) return;
    const props: Record<string, unknown> = { fcm_token: token };
    if (prev) props.prev_token = prev;
    UniTrack.track('fcm_token_updated', props);
  }

  /** Wire to `messaging().onMessage(...)`. Foreground push arrival. */
  static handleNotificationReceivedForeground(m: RemoteMessageLite): void {
    UniTrack.trackNotification({
      state: 'foreground',
      action: 'received',
      title: m.notification?.title,
      body:  m.notification?.body,
      notificationId: UniTrackFirebaseMessaging.idOf(m),
      data: UniTrackFirebaseMessaging.safeData(m.data),
    });
  }

  /** Wire to `messaging().onNotificationOpenedApp(...)` AND
   *  `messaging().getInitialMessage()`. Treated as user engagement. */
  static handleNotificationClicked(m: RemoteMessageLite): void {
    UniTrack.trackNotification({
      state: 'foreground',
      action: 'clicked',
      title: m.notification?.title,
      body:  m.notification?.body,
      notificationId: UniTrackFirebaseMessaging.idOf(m),
      data: UniTrackFirebaseMessaging.safeData(m.data),
    });
  }

  /** Wire to `messaging().setBackgroundMessageHandler(...)`. Background /
   *  silent arrival. */
  static handleBackgroundMessage(m: RemoteMessageLite): void {
    const hasVisible = m.notification != null;
    UniTrack.trackNotification({
      state: hasVisible ? 'background' : 'silent',
      action: 'received',
      title: m.notification?.title,
      body:  m.notification?.body,
      notificationId: UniTrackFirebaseMessaging.idOf(m),
      data: UniTrackFirebaseMessaging.safeData(m.data),
    });
  }

  // ── internal ─────────────────────────────────────────────────────────

  private static idOf(m: RemoteMessageLite): string | undefined {
    if (m.messageId) return m.messageId;
    const d = m.data ?? {};
    const g = d['gcm.message_id'] ?? d['google.message_id'];
    return typeof g === 'string' && g ? g : undefined;
  }

  private static safeData(
    data: Record<string, string | number | boolean> | undefined,
  ): Record<string, unknown> {
    if (!data) return {};
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(data)) out[k] = data[k];
    return out;
  }
}

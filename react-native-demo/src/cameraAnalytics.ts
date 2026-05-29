// Camera/CCTV event taxonomy on UniTrack (mirrors the iOS/Android camera demos).
//
// The SDK auto-captures screen_view, tap, network_request, session boundaries
// and (via App.tsx) uncaught-error `crash`. The domain events below are explicit
// track() calls — an analytics SDK can't infer "live stream started" from UI.
// This is the single tracking surface for the whole app.

import UniTrack from '@unitrack/react-native';

const t = (event: string, props?: Record<string, unknown>) =>
  UniTrack.track(event, props);

export const CameraAnalytics = {
  // Session (the SDK also emits its own session_start/end via journeyCapture).
  sessionStarted: () => t('session_started', {source: 'app_open'}),
  sessionEnded: (reason: string) => t('session_ended', {reason}),

  // Live streaming B2C (#5,6,7) + perf (#27,28)
  streamStarted: (cameraId: string, quality: string) =>
    t('camera_stream_started', {camera_id: cameraId, quality}),
  streamPaused: (cameraId: string) =>
    t('camera_stream_paused', {camera_id: cameraId}),
  streamEnded: (cameraId: string, durationMs: number) =>
    t('camera_stream_ended', {camera_id: cameraId, duration_ms: durationMs}),
  streamFirstFrame: (cameraId: string, ttffMs: number) =>
    t('camera_stream_first_frame', {camera_id: cameraId, ttff_ms: ttffMs}),
  streamBuffering: (cameraId: string, durationMs: number) =>
    t('camera_stream_buffering', {camera_id: cameraId, duration_ms: durationMs}),

  // Events & playback B2C (#8,9,10)
  eventViewed: (cameraId: string, eventType: string) =>
    t('camera_event_viewed', {camera_id: cameraId, event_type: eventType}),
  playbackStarted: (cameraId: string, recordingId: string) =>
    t('camera_playback_started', {camera_id: cameraId, recording_id: recordingId}),
  playbackEnded: (cameraId: string, durationMs: number) =>
    t('camera_playback_ended', {camera_id: cameraId, duration_ms: durationMs}),

  // Notifications (#11–14)
  notificationPermissionChecked: (granted: boolean) =>
    t('notification_permission_checked', {granted}),
  notificationSent: (cameraId: string, type: string) =>
    t('camera_notification_sent', {camera_id: cameraId, type}),
  notificationDelivered: (cameraId: string, type: string) =>
    t('camera_notification_delivered', {camera_id: cameraId, type}),
  notificationClicked: (cameraId: string, type: string) =>
    t('camera_notification_clicked', {camera_id: cameraId, type}),

  // Settings B2C (#15)
  aiFeatureToggled: (cameraId: string, feature: string, enabled: boolean) =>
    t('camera_ai_feature_toggled', {camera_id: cameraId, feature, enabled}),

  // VMS B2B (#16–19)
  vmsCameraConnected: (nvrId: string, channel: number) =>
    t('vms_camera_connected', {nvr_id: nvrId, channel}),
  vmsCameraDisconnected: (nvrId: string, channel: number) =>
    t('vms_camera_disconnected', {nvr_id: nvrId, channel}),
  vmsRecordingPlayed: (nvrId: string, channel: number, recordingId: string) =>
    t('vms_recording_played', {nvr_id: nvrId, channel, recording_id: recordingId}),
  vmsAlertViewed: (nvrId: string, alertType: string) =>
    t('vms_alert_viewed', {nvr_id: nvrId, alert_type: alertType}),

  // Sharing B2C (#20,21)
  cameraShared: (cameraId: string, withUser: string) =>
    t('camera_shared', {camera_id: cameraId, shared_with: withUser}),
  cameraShareRevoked: (cameraId: string, fromUser: string) =>
    t('camera_share_revoked', {camera_id: cameraId, revoked_from: fromUser}),

  // Onboarding / pairing (#22–25)
  pairingStarted: (method: string) => t('camera_pairing_started', {method}),
  pairingCompleted: (cameraId: string, durationMs: number) =>
    t('camera_pairing_completed', {camera_id: cameraId, duration_ms: durationMs}),
  pairingFailed: (reason: string, code: string) =>
    t('camera_pairing_failed', {reason, error_code: code}),
  cameraRegistered: (cameraId: string, model: string) =>
    t('camera_registered', {camera_id: cameraId, model}),

  // Interactions & errors (#29,30)
  cameraItemSelected: (cameraId: string, position: number) =>
    t('camera_item_selected', {camera_id: cameraId, position}),
  applicationError: (domain: string, message: string, fatal = false) =>
    t('application_error', {domain, message, fatal}),
};

// Fire realistic backend calls so the SDK auto-captures network_request. Uses
// httpbin.org/status/<code> with the logical path as a query so URLs are
// self-describing in the portal. Sequenced with small delays to read as a flow.
export function apiCall(path: string, method = 'GET', status = 200) {
  const url = `https://httpbin.org/status/${status}?path=${encodeURIComponent(path)}`;
  fetch(url, {method}).catch(() => {});
}
export function apiSequence(calls: Array<[string, string, number]>) {
  calls.forEach(([path, method, status], i) =>
    setTimeout(() => apiCall(path, method, status), i * 250),
  );
}

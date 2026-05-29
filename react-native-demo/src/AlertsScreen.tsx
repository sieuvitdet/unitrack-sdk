// Alerts + notification lifecycle + misc helpers + a real crash (screen_view "Alerts").
import React from 'react';
import {Text, Linking} from 'react-native';
import {Btn, Screen} from './ui';
import UniTrack, {safeJsonParse} from '@unitrack/react-native';
// (safeJsonParse is re-exported as a named export from the package index.)
import {CameraAnalytics} from './cameraAnalytics';

export default function AlertsScreen() {
  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>Cảnh báo & sự kiện</Text>

      <Btn title="🔔  Mô phỏng cảnh báo chuyển động" testID="notif_motion_alert"
        onPress={() => {
          CameraAnalytics.notificationSent('cam_front_door', 'motion');
          UniTrack.trackNotification({state: 'foreground', action: 'received',
            title: 'Phát hiện chuyển động', body: 'Camera Cửa trước phát hiện chuyển động'});
          CameraAnalytics.notificationDelivered('cam_front_door', 'motion');
        }} />
      <Btn title="👆  Mô phỏng bấm vào thông báo" testID="notif_clicked" tone="plain"
        onPress={() => {
          UniTrack.trackNotification({state: 'background', action: 'opened', title: 'Phát hiện chuyển động'});
          CameraAnalytics.notificationClicked('cam_front_door', 'motion');
        }} />

      <Btn title="🔗  Mở MobiX qua deeplink" testID="open_mobix_deeplink" tone="plain"
        onPress={() => {
          const url = 'mobix://open?screen=detail&id=123';
          UniTrack.trackDeeplink(url, 'rn_camera_demo');
          Linking.openURL(url).catch(() => {});
        }} />
      <Btn title="🌐  Mở WebView" testID="open_webview" tone="plain"
        onPress={() => UniTrack.trackWebViewOpen('https://mobix.asia/help/cameras')} />

      <Btn title="💥  Báo lỗi xử lý (non-fatal)" testID="report_error" tone="plain"
        onPress={() => CameraAnalytics.applicationError('StreamDecoder', 'Failed to decode H.265 frame')} />
      <Btn title="🧩  Parse JSON lỗi" testID="bad_json" tone="plain"
        onPress={() => safeJsonParse('CameraDto', '{ this is : not valid json ]')} />
      <Btn title="🧨  Gây crash thật" testID="force_crash" tone="danger"
        onPress={() => { const a: any = undefined; a.boom(); }} />
    </Screen>
  );
}

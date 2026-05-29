// B2B VMS/NVR flow (screen_view "VMS").
import React, {useRef} from 'react';
import {Text} from 'react-native';
import {Btn, Screen} from './ui';
import {CameraAnalytics} from './cameraAnalytics';

export default function VmsScreen() {
  const nvrId = 'nvr_hq_01';
  const channel = useRef<number | null>(null);
  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>VMS (B2B)</Text>
      <Btn title="🔌  Kết nối camera kênh 3" testID="vms_connect"
        onPress={() => {channel.current = 3; CameraAnalytics.vmsCameraConnected(nvrId, 3);}} />
      <Btn title="🔕  Ngắt kết nối" testID="vms_disconnect" tone="plain"
        onPress={() => {if (channel.current) {CameraAnalytics.vmsCameraDisconnected(nvrId, channel.current); channel.current = null;}}} />
      <Btn title="⏯  Phát lại bản ghi NVR" testID="vms_playback" tone="plain"
        onPress={() => CameraAnalytics.vmsRecordingPlayed(nvrId, 3, 'nvr_rec_88')} />
      <Btn title="⚠️  Xem cảnh báo NVR" testID="vms_alert" tone="plain"
        onPress={() => CameraAnalytics.vmsAlertViewed(nvrId, 'line_crossing')} />
    </Screen>
  );
}

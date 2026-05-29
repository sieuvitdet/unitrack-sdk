// Camera onboarding / pairing flow (screen_view "Pairing").
import React, {useRef} from 'react';
import {Text} from 'react-native';
import {Btn, Screen} from './ui';
import {CameraAnalytics} from './cameraAnalytics';

export default function PairingScreen() {
  const start = useRef<number>(0);
  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>Thêm Camera</Text>
      <Btn title="📡  Bắt đầu ghép nối (QR)" testID="pairing_start"
        onPress={() => {start.current = Date.now(); CameraAnalytics.pairingStarted('qr_code');}} />
      <Btn title="✅  Ghép nối thành công" testID="pairing_success"
        onPress={() => {
          CameraAnalytics.pairingCompleted('cam_new_99', start.current ? Date.now() - start.current : 0);
          CameraAnalytics.cameraRegistered('cam_new_99', 'MobiCam Pro 2K');
        }} />
      <Btn title="❌  Ghép nối thất bại" testID="pairing_fail" tone="danger"
        onPress={() => CameraAnalytics.pairingFailed('wifi_timeout', 'E_TIMEOUT')} />
    </Screen>
  );
}

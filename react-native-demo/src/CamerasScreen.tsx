// B2C camera list. Selecting a camera opens the live-stream screen.
// screen_view "Cameras" + tap (testID camera_item_*) auto-captured.
import React from 'react';
import {Text} from 'react-native';
import {Btn, Screen} from './ui';
import {CameraAnalytics, apiCall} from './cameraAnalytics';

const CAMERAS = [
  ['cam_living_room', 'Phòng khách'],
  ['cam_front_door', 'Cửa trước'],
  ['cam_garage', 'Nhà xe'],
];

export default function CamerasScreen({navigation}: any) {
  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>Cameras (B2C)</Text>
      {CAMERAS.map(([id, name], i) => (
        <Btn
          key={id}
          title={`📹  ${name}`}
          testID={`camera_item_${id}`}
          onPress={() => {
            CameraAnalytics.cameraItemSelected(id, i);
            navigation.navigate('LiveStream', {cameraId: id, cameraName: name});
          }}
        />
      ))}
      <Btn
        title="🔄  Tải danh sách (API)"
        testID="camera_list_refresh"
        tone="plain"
        onPress={() => apiCall('/v1/cameras', 'GET', 200)}
      />
      <Text style={{marginTop: 8, color: '#888'}}>Khác:</Text>
      <Btn title="🖥  VMS (B2B)" testID="nav_vms" tone="plain" onPress={() => navigation.navigate('VMS')} />
      <Btn title="➕  Thêm camera" testID="nav_pairing" tone="plain" onPress={() => navigation.navigate('Pairing')} />
      <Btn title="🔔  Cảnh báo" testID="nav_alerts" tone="plain" onPress={() => navigation.navigate('Alerts')} />
      <Btn title="⚙️  Cài đặt" testID="nav_settings" tone="plain" onPress={() => navigation.navigate('Settings')} />
    </Screen>
  );
}

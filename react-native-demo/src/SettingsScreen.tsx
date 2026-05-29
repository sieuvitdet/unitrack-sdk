// Camera settings + sharing + user identity (screen_view "Settings").
import React, {useState} from 'react';
import {Text, View, Switch, StyleSheet} from 'react-native';
import {Btn, Screen} from './ui';
import UniTrack from '@unitrack/react-native';
import {CameraAnalytics} from './cameraAnalytics';

const cameraId = 'cam_living_room';
// Alternate between two demo users so the portal shows per-user filtering.
const USERS: Array<[string, string]> = [
  ['rn_user_alpha', 'b2c_premium'],
  ['rn_user_beta', 'b2c_basic'],
];
let loginIdx = 0;

export default function SettingsScreen() {
  const [person, setPerson] = useState(false);
  const [motion, setMotion] = useState(false);
  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>Cài đặt</Text>

      <View style={styles.row}>
        <Text style={styles.label}>AI nhận diện người</Text>
        <Switch testID="ai_person_detection" value={person}
          onValueChange={v => {setPerson(v); CameraAnalytics.aiFeatureToggled(cameraId, 'person_detection', v);}} />
      </View>
      <View style={styles.row}>
        <Text style={styles.label}>AI phát hiện chuyển động</Text>
        <Switch testID="ai_motion" value={motion}
          onValueChange={v => {setMotion(v); CameraAnalytics.aiFeatureToggled(cameraId, 'motion', v);}} />
      </View>

      <Btn title="👥  Chia sẻ camera" testID="camera_share"
        onPress={() => CameraAnalytics.cameraShared(cameraId, 'friend_07')} />
      <Btn title="🚫  Thu hồi chia sẻ" testID="camera_share_revoke" tone="plain"
        onPress={() => CameraAnalytics.cameraShareRevoked(cameraId, 'friend_07')} />

      <Btn title="🔑  Đăng nhập (đổi user)" testID="login" tone="plain"
        onPress={() => {
          const [id, plan] = USERS[loginIdx % USERS.length];
          loginIdx++;
          UniTrack.identify(id, {plan, region: 'VN'});
        }} />
      <Btn title="🚪  Đăng xuất (reset)" testID="logout" tone="plain"
        onPress={() => UniTrack.reset()} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  label: {fontSize: 16},
});

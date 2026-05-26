// Settings — plain UI. Tracking toggle uses the SDK's setEnabled (a runtime
// control, not per-event tracking). The crash buttons demonstrate JS error
// capture (reported as `crash` via the global error handler in App.tsx).
import React, {useState} from 'react';
import {Switch, Text, View, StyleSheet} from 'react-native';
import UniTrack from '@unitrack/react-native';
import {Btn, Screen} from './ui';

export default function SettingsScreen() {
  const [enabled, setEnabled] = useState(true);

  return (
    <Screen>
      <View style={styles.row}>
        <Text style={styles.label}>Bật tracking</Text>
        <Switch
          testID="settings_tracking_switch"
          value={enabled}
          onValueChange={v => {
            setEnabled(v);
            UniTrack.setEnabled(v);
          }}
        />
      </View>

      <Btn
        testID="settings_crash_sync"
        title="Gây lỗi (sync)"
        tone="danger"
        onPress={() => {
          throw new Error('Intentional sync crash from Settings');
        }}
      />
      <Btn
        testID="settings_crash_async"
        title="Gây lỗi (async)"
        tone="danger"
        onPress={() => {
          setTimeout(() => {
            throw new Error('Intentional async crash from Settings');
          }, 50);
        }}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  row: {flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center'},
  label: {fontSize: 16},
});

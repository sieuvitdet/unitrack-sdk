import React, { useState } from 'react';
import {
  SafeAreaView, ScrollView, Text, TouchableOpacity, View, StyleSheet,
} from 'react-native';
import { UniTrack } from 'unitrack-react-native';

// 3 button, 3 kịch bản. Native host phải in cùng session_id ở console —
// đọc console iOS (Xcode) hoặc `adb logcat -s UniTrack` (Android).
export default function App() {
  const [log, setLog] = useState<string[]>([]);
  const append = (s: string) =>
    setLog((prev) => [`${new Date().toISOString().slice(11, 19)}  ${s}`, ...prev].slice(0, 20));

  const onTrack = async () => {
    await UniTrack.track('rn_button_track', { source: 'rn', click_index: 1 });
    append('track(rn_button_track) sent');
  };

  const onCustomTrack = async () => {
    await UniTrack.customTrack('rn_custom_event', {
      action: 'button_press',
      data: { screen: 'RN', value: 42 },
      includeUser: false,
    });
    append('customTrack(rn_custom_event) sent');
  };

  const onCheckSession = async () => {
    // Nếu co-resident: giá trị này = native singleton.currentSessionId().
    // In cả 2 giá trị (host in ở AppDelegate console) để so sánh mắt thường.
    const sid = await UniTrack.currentSessionId();
    const idx = await UniTrack.sessionIndex();
    append(`session_id=${sid}  index=${idx}`);
  };

  const onFlush = async () => {
    await UniTrack.flush();
    append('flush() called');
  };

  const onCounts = async () => {
    const c = await UniTrack.pendingEventCounts();
    append(`pending=${JSON.stringify(c)}`);
  };

  return (
    <SafeAreaView style={styles.root}>
      <Text style={styles.h1}>UniTrack RN cross-binary</Text>
      <Text style={styles.h2}>
        Host app phải init UniTrack native trước. RN gọi các API dưới → HostProxy
        forward về singleton native. Session_id in dưới = native session_id.
      </Text>
      <View style={styles.buttons}>
        <Btn title="1. track()"          onPress={onTrack} />
        <Btn title="2. customTrack()"    onPress={onCustomTrack} />
        <Btn title="3. currentSessionId" onPress={onCheckSession} />
        <Btn title="flush()"             onPress={onFlush} />
        <Btn title="pendingEventCounts"  onPress={onCounts} />
      </View>
      <ScrollView style={styles.log}>
        {log.map((l, i) => <Text key={i} style={styles.logLine}>{l}</Text>)}
      </ScrollView>
    </SafeAreaView>
  );
}

const Btn = ({ title, onPress }: { title: string; onPress: () => void }) => (
  <TouchableOpacity style={styles.btn} onPress={onPress}>
    <Text style={styles.btnText}>{title}</Text>
  </TouchableOpacity>
);

const styles = StyleSheet.create({
  root:    { flex: 1, backgroundColor: '#0d1117', padding: 16 },
  h1:      { color: '#61dafb', fontSize: 20, fontWeight: '600', marginBottom: 4 },
  h2:      { color: '#8b949e', fontSize: 12, marginBottom: 12, lineHeight: 18 },
  buttons: { gap: 8 },
  btn:     { backgroundColor: '#238636', padding: 12, borderRadius: 6 },
  btnText: { color: '#fff', fontSize: 14, fontWeight: '500', textAlign: 'center' },
  log:     { flex: 1, marginTop: 16, backgroundColor: '#161b22', borderRadius: 6, padding: 8 },
  logLine: { color: '#c9d1d9', fontSize: 11, fontFamily: 'Menlo', marginBottom: 2 },
});

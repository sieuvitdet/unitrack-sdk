// Network demo — plain UI. fetch() calls are auto-captured by the SDK, and the
// button that triggered each call is mirrored onto the event. No tracking code.
import React, {useState} from 'react';
import {Text, ScrollView, StyleSheet} from 'react-native';
import {Btn, Screen} from './ui';

export default function NetworkScreen() {
  const [log, setLog] = useState('Bấm nút để gọi API.\n');
  const append = (s: string) => setLog(p => p + s + '\n');

  const get200 = async () => {
    try {
      const r = await fetch('https://jsonplaceholder.typicode.com/todos/1');
      append(`GET /todos/1 -> ${r.status}`);
    } catch (e) {
      append(`error: ${e}`);
    }
  };
  const post = async () => {
    try {
      const r = await fetch('https://jsonplaceholder.typicode.com/posts', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({title: 'mobix', body: 'demo', userId: 1}),
      });
      append(`POST /posts -> ${r.status}`);
    } catch (e) {
      append(`error: ${e}`);
    }
  };
  const get404 = async () => {
    try {
      const r = await fetch('https://jsonplaceholder.typicode.com/nope-404');
      append(`GET /nope-404 -> ${r.status}`);
    } catch (e) {
      append(`error: ${e}`);
    }
  };
  const badHost = async () => {
    try {
      await fetch('https://this-host-does-not-exist.mobix.invalid/x');
    } catch (e) {
      append(`network error (tracked): ${e}`);
    }
  };

  return (
    <Screen>
      <Btn testID="net_get_200" title="GET 200" onPress={get200} />
      <Btn testID="net_post" title="POST" onPress={post} />
      <Btn testID="net_get_404" title="GET 404" tone="plain" onPress={get404} />
      <Btn testID="net_bad_host" title="Bad host" tone="plain" onPress={badHost} />
      <ScrollView style={styles.log}>
        <Text style={styles.logText}>{log}</Text>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  log: {flex: 1, backgroundColor: '#0b0e14', borderRadius: 12, padding: 12, marginTop: 8},
  logText: {color: '#27d796', fontFamily: 'Menlo', fontSize: 12},
});

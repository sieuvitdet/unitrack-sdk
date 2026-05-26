// Tiny shared UI bits. No tracking code — taps are captured globally.

import React from 'react';
import {Pressable, Text, StyleSheet, View} from 'react-native';

export function Btn(props: {
  title: string;
  testID?: string;
  onPress: () => void;
  tone?: 'primary' | 'danger' | 'plain';
}) {
  const tone = props.tone ?? 'primary';
  return (
    <Pressable
      testID={props.testID}
      accessibilityLabel={props.testID}
      onPress={props.onPress}
      style={({pressed}) => [
        styles.btn,
        tone === 'danger' && styles.danger,
        tone === 'plain' && styles.plain,
        pressed && styles.pressed,
      ]}>
      <Text style={[styles.btnText, tone === 'plain' && styles.plainText]}>
        {props.title}
      </Text>
    </Pressable>
  );
}

export function Screen(props: {children: React.ReactNode}) {
  return <View style={styles.screen}>{props.children}</View>;
}

const styles = StyleSheet.create({
  screen: {flex: 1, padding: 20, gap: 12, backgroundColor: '#fff'},
  btn: {
    backgroundColor: '#5B8CFF',
    paddingVertical: 14,
    paddingHorizontal: 18,
    borderRadius: 12,
    alignItems: 'center',
  },
  danger: {backgroundColor: '#FF6B6B'},
  plain: {backgroundColor: '#EEF1F6'},
  plainText: {color: '#1b2231'},
  pressed: {opacity: 0.7},
  btnText: {color: '#fff', fontSize: 16, fontWeight: '600'},
});

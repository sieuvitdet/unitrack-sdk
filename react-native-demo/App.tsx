// Mobix UniTrack — React Native CAMERA demo (mirrors the iOS/Android camera demos).
//
// ALL tracking setup is here; the screens have zero tracking plumbing:
//   1. UniTrack.initialize(...)      → SDK + transport to the portal
//   2. createNavigationTracker()     → screen_view per route
//   3. <UniTrackTapBoundary>         → every tap (button testID + screen)
// fetch() is auto-captured as network_request; uncaught JS errors → `crash`.

import React, {useEffect} from 'react';
import {NavigationContainer} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import UniTrack, {
  UniTrackTapBoundary,
  createNavigationTracker,
  UniTrackRemoteConfig,
} from '@unitrack/react-native';

import CamerasScreen from './src/CamerasScreen';
import LiveStreamScreen from './src/LiveStreamScreen';
import VmsScreen from './src/VmsScreen';
import PairingScreen from './src/PairingScreen';
import AlertsScreen from './src/AlertsScreen';
import SettingsScreen from './src/SettingsScreen';
import {CameraAnalytics} from './src/cameraAnalytics';

const Stack = createNativeStackNavigator();
const nav = createNavigationTracker();

declare const ErrorUtils: any;

const API_KEY = 'utk_Nfn_ex3MZRNL1Yith0GL0X5q';   // project "Demo React Native"
const CONFIG_URL = 'https://mobix.asia/event-tracking-mobile/config';

export default function App() {
  useEffect(() => {
    (async () => {
      const cfg = await UniTrackRemoteConfig.fetch(API_KEY, CONFIG_URL, 3000);
      UniTrack.setEventRules(UniTrackRemoteConfig.toEventRules(cfg));
      const s = cfg.sdk_config ?? {};
      await UniTrack.initialize(API_KEY, {
        endpoint: cfg.endpoint ?? 'https://mobix.asia/event-tracking-mobile/v1/events',
        batchSize: (s.batchSize as number) ?? 5,
        flushIntervalMs: (s.flushIntervalMs as number) ?? 2000,
        samplingRate: (s.samplingRate as number) ?? 1.0,
        autoCapture: (s.autoCapture as boolean) ?? true,
      });
      await UniTrack.identify('rn_user_alpha', {plan: 'b2c_premium', region: 'VN'});
      CameraAnalytics.sessionStarted();
    })();

    // Uncaught JS errors → crash (a JS throw is not a native signal).
    const prior = ErrorUtils?.getGlobalHandler?.();
    ErrorUtils?.setGlobalHandler?.((error: any, isFatal?: boolean) => {
      UniTrack.track('crash', {
        type: error?.name ?? 'Error',
        message: String(error?.message ?? error),
        fatal: !!isFatal,
        stack: String(error?.stack ?? '').split('\n').slice(0, 20).join('\n'),
        platform: 'react-native',
      });
      UniTrack.flush();
      prior?.(error, isFatal);
    });
  }, []);

  return (
    <UniTrackTapBoundary>
      <NavigationContainer
        ref={nav.ref}
        onReady={nav.onReady}
        onStateChange={nav.onStateChange}>
        <Stack.Navigator initialRouteName="Cameras">
          <Stack.Screen name="Cameras" component={CamerasScreen} options={{title: 'Cameras'}} />
          <Stack.Screen name="LiveStream" component={LiveStreamScreen} options={{title: 'Live stream'}} />
          <Stack.Screen name="VMS" component={VmsScreen} options={{title: 'VMS (B2B)'}} />
          <Stack.Screen name="Pairing" component={PairingScreen} options={{title: 'Thêm Camera'}} />
          <Stack.Screen name="Alerts" component={AlertsScreen} options={{title: 'Cảnh báo'}} />
          <Stack.Screen name="Settings" component={SettingsScreen} options={{title: 'Cài đặt'}} />
        </Stack.Navigator>
      </NavigationContainer>
    </UniTrackTapBoundary>
  );
}

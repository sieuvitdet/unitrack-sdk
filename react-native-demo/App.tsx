// Mobix UniTrack — React Native demo.
//
// THE ENTIRE TRACKING SETUP IS HERE. The screens contain ZERO tracking code.
// Three pieces wire up everything:
//   1. UniTrack.initialize(...)            → SDK + transport to the portal
//   2. createNavigationTracker()           → screen_view per route
//   3. <UniTrackTapBoundary>               → every tap (button name + screen)
// Network requests (fetch) are auto-captured by the SDK, with the button that
// triggered them mirrored in. Uncaught JS errors are reported as `crash`.

import React, {useEffect} from 'react';
import {NavigationContainer} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import UniTrack, {
  UniTrackTapBoundary,
  createNavigationTracker,
  UniTrackRemoteConfig,
} from '@unitrack/react-native';

import HomeScreen from './src/HomeScreen';
import ProductsScreen from './src/ProductsScreen';
import ProductDetailScreen from './src/ProductDetailScreen';
import NetworkScreen from './src/NetworkScreen';
import SettingsScreen from './src/SettingsScreen';

const Stack = createNativeStackNavigator();
const nav = createNavigationTracker();

declare const ErrorUtils: any;

const API_KEY = 'utk_FPxp0q7RK3jja0CnFp3WEx9Q';
const CONFIG_URL = 'https://mobix.asia/event-tracking-mobile/config';

export default function App() {
  useEffect(() => {
    // Fetch remote config first (cache/default fallback), install rewrite rules,
    // then initialize the SDK from it — so config/rules change without a rebuild.
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
    })();

    // Report uncaught JS errors as crash events. (A JS throw is not a native
    // signal, so the native crash handler never sees it — hook it here.)
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
        <Stack.Navigator initialRouteName="Home">
          <Stack.Screen name="Home" component={HomeScreen} options={{title: 'Mobix RN Demo'}} />
          <Stack.Screen name="Products" component={ProductsScreen} options={{title: 'Cửa hàng'}} />
          <Stack.Screen name="ProductDetail" component={ProductDetailScreen} options={{title: 'Chi tiết'}} />
          <Stack.Screen name="Network" component={NetworkScreen} options={{title: 'Network demo'}} />
          <Stack.Screen name="Settings" component={SettingsScreen} options={{title: 'Cài đặt'}} />
        </Stack.Navigator>
      </NavigationContainer>
    </UniTrackTapBoundary>
  );
}

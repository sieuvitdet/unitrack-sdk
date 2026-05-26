// Home — plain UI. No tracking code; taps/screens captured globally.
import React from 'react';
import {Btn, Screen} from './ui';

export default function HomeScreen({navigation}: any) {
  return (
    <Screen>
      <Btn testID="home_open_products" title="Xem sản phẩm"
        onPress={() => navigation.navigate('Products')} />
      <Btn testID="home_open_network" title="Network demo"
        onPress={() => navigation.navigate('Network')} />
      <Btn testID="home_open_settings" title="Cài đặt" tone="plain"
        onPress={() => navigation.navigate('Settings')} />
      {/* No testID → the SDK falls back to the button's text label. */}
      <Btn title="Nút không có ID" tone="plain" onPress={() => {}} />
    </Screen>
  );
}

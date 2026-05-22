// React Native example. Minimum integration.

import React, { useEffect } from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import UniTrack, {
  createNavigationTracker,
  safeJsonParse,
} from '@unitrack/react-native';
import { Button, View } from 'react-native';

const Stack = createNativeStackNavigator();

function HomeScreen() {
  return (
    <View>
      {/* `testID` becomes the tracked element_key */}
      <Button
        testID="home_buy_now_btn"
        title="Buy now"
        onPress={() => UniTrack.track('checkout_started', { source: 'home' })}
      />
    </View>
  );
}

export default function App() {
  const nav = createNavigationTracker();

  useEffect(() => {
    UniTrack.initialize('YOUR_API_KEY', {
      endpoint: 'https://ingest.example.com/v1/events',
      samplingRate: 1.0,
    });
  }, []);

  return (
    <NavigationContainer
      ref={nav.ref}
      onReady={nav.onReady}
      onStateChange={nav.onStateChange}
    >
      <Stack.Navigator>
        <Stack.Screen name="Home" component={HomeScreen} />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

// Safe JSON helper anywhere:
//
//   const user = safeJsonParse<User>('User', body);
//
// Network calls via global `fetch` are auto-tracked.

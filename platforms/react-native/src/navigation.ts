// React Navigation integration. Drop into NavigationContainer:
//
//   const ref = useNavigationContainerRef();
//   return (
//     <NavigationContainer
//       ref={ref}
//       onReady={() => UniTrackNav.onReady(ref)}
//       onStateChange={UniTrackNav.onStateChange}
//     />
//   );
//
// or use the helper:
//
//   const { ref, ...handlers } = createNavigationTracker();
//   <NavigationContainer ref={ref} {...handlers} />

import UniTrack from './index';
import { tapState } from './tapState';

let currentRouteName: string | undefined;

function setScreen(name: string) {
  currentRouteName = name;
  tapState.currentScreen = name;   // so taps + network events carry the screen
  UniTrack.setScreen(name);
}

function getActiveRouteName(state: any): string | undefined {
  if (!state || typeof state.index !== 'number') return undefined;
  const route = state.routes[state.index];
  if (route?.state) return getActiveRouteName(route.state);
  return route?.name;
}

export default function createNavigationTracker() {
  const ref: { current: any } = { current: null };

  return {
    ref,
    onReady: () => {
      const name = ref.current?.getCurrentRoute?.()?.name;
      if (name) setScreen(name);
    },
    onStateChange: (state: any) => {
      const name = getActiveRouteName(state);
      if (name && name !== currentRouteName) setScreen(name);
    },
  };
}

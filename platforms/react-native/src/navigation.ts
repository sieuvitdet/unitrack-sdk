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

let currentRouteName: string | undefined;

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
      if (name) {
        currentRouteName = name;
        UniTrack.setScreen(name);
      }
    },
    onStateChange: (state: any) => {
      const name = getActiveRouteName(state);
      if (name && name !== currentRouteName) {
        currentRouteName = name;
        UniTrack.setScreen(name);
      }
    },
  };
}

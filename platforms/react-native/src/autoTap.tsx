// UniTrack React Native — JS-layer tap auto-capture.
//
// React Native maps components to real native views, so the native SDK's tap
// swizzlers DO fire — but they only see the native view class (e.g. RCTView),
// not the JS component / testID. To capture a meaningful button name we wrap
// the app once and inspect the React Fiber tree of whatever was tapped.
//
// Usage — declare ONCE at the root:
//
//   import { UniTrackTapBoundary } from '@unitrack/react-native';
//
//   export default function App() {
//     return (
//       <UniTrackTapBoundary>
//         <NavigationContainer ...>{/* your app */}</NavigationContainer>
//       </UniTrackTapBoundary>
//     );
//   }
//
// After that every press is tracked as a `tap` event with the element name,
// resolved from: testID -> accessibilityLabel -> nearest Text -> component name.
// No per-button code is required.

import React from 'react';
import { View } from 'react-native';
import UniTrack from './index';
import { tapState } from './tapState';

export { tapState } from './tapState';
export type { LastTap } from './tapState';

/** Walk up the React Fiber tree from the touched node to find a good name. */
function resolveName(fiber: any): { name: string; type: string } | null {
  let node = fiber;
  let testID: string | undefined;
  let label: string | undefined;
  let text: string | undefined;
  let componentName: string | undefined;
  let pressableType: string | undefined;

  let depth = 0;
  while (node && depth < 40) {
    const props = node.memoizedProps ?? node.pendingProps;
    if (props) {
      if (!testID && typeof props.testID === 'string' && props.testID) {
        testID = props.testID;
      }
      if (!label && typeof props.accessibilityLabel === 'string' && props.accessibilityLabel) {
        label = props.accessibilityLabel;
      }
      // First string child encountered going up = button label text.
      if (!text && typeof props.children === 'string' && props.children.trim()) {
        text = props.children.trim();
      }
      // Detect pressable wrappers by their handler props.
      if (!pressableType && (props.onPress || props.onPressIn || props.onLongPress)) {
        pressableType = elementName(node) ?? 'Pressable';
      }
    }
    if (!componentName) componentName = elementName(node);
    node = node.return;
    depth++;
  }

  const name = testID ?? label ?? text ?? pressableType ?? componentName;
  if (!name) return null;
  return { name, type: pressableType ?? componentName ?? 'unknown' };
}

function elementName(fiber: any): string | undefined {
  const t = fiber?.type;
  if (!t) return undefined;
  if (typeof t === 'string') return t; // host component, e.g. 'RCTView'
  return t.displayName || t.name || undefined;
}

interface Props { children: React.ReactNode }

/**
 * Wrap your app once with this. It uses a capture-phase responder so it observes
 * every touch without interfering with the components' own press handling.
 */
export class UniTrackTapBoundary extends React.Component<Props> {
  private lastKey = '';
  private lastAt = 0;

  private onCapture = (e: any): boolean => {
    try {
      const target = e?._targetInst ?? e?.target?._internalFiberInstanceHandleDEV;
      const resolved = target ? resolveName(target) : null;
      if (resolved) {
        const now = Date.now();
        // Debounce identical rapid taps.
        if (!(resolved.name === this.lastKey && now - this.lastAt < 250)) {
          this.lastKey = resolved.name;
          this.lastAt = now;
          const screen = tapState.currentScreen;
          tapState.last = { element: resolved.name, screen, at: now };
          UniTrack.track('tap', {
            element: resolved.name,
            element_type: resolved.type,
            screen,
          });
        }
      }
    } catch {
      // Never let tracking break touch handling.
    }
    return false; // do not become the responder; let the real target handle it
  };

  render() {
    return (
      <View
        style={{ flex: 1 }}
        onStartShouldSetResponderCapture={this.onCapture}
      >
        {this.props.children}
      </View>
    );
  }
}

export default UniTrackTapBoundary;

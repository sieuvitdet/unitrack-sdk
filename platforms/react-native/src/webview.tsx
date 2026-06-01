// UniTrack WebView auto-capture helper for React Native.
//
// The community `react-native-webview` component exposes
// `onNavigationStateChange` and `onLoadStart` — wrap either with a HOC that
// fires UniTrack events.
//
// Usage:
//   import { WebView } from 'react-native-webview';
//   import { withUniTrackWebView } from 'unitrack/webview';
//   const TrackedWebView = withUniTrackWebView(WebView);
//   // ...then use <TrackedWebView source={{uri}} ... /> as you would WebView.
//
// We avoid importing react-native-webview from this file — apps that don't
// use webviews shouldn't pay the dependency cost. The HOC accepts any
// component with `onNavigationStateChange` and `onLoadStart` props.

import React from 'react';
import UniTrack from './index';

interface NavigationStateLike { url?: string }
interface WebViewLikeProps {
  onLoadStart?: (e: { nativeEvent?: { url?: string } }) => void;
  onNavigationStateChange?: (s: NavigationStateLike) => void;
}

/**
 * Wrap a WebView component so the SDK sees URL changes.
 *
 * - First load (or host change) → `webview_open` with the URL.
 * - Same-host navigations → `webview_navigate`.
 *
 * Existing onLoadStart / onNavigationStateChange handlers on the wrapped
 * component still fire — we chain instead of replacing.
 */
export function withUniTrackWebView<P extends WebViewLikeProps>(
  Wrapped: React.ComponentType<P>,
): React.ComponentType<P> {
  return function UniTrackedWebView(props: P) {
    // Per-instance ref — kept in a ref so component re-renders don't reset it.
    const firstHostRef = React.useRef<string | null>(null);

    const reportUrl = React.useCallback((url: string | undefined) => {
      if (!url) return;
      let host: string | null = null;
      try { host = new URL(url).host; } catch (_) { /* malformed — skip host */ }
      const current = firstHostRef.current;
      if (current === null || current !== host) {
        firstHostRef.current = host;
        UniTrack.trackWebViewOpen(url);
      } else {
        UniTrack.track('webview_navigate', { url });
      }
    }, []);

    const onLoadStart = React.useCallback(
      (e: { nativeEvent?: { url?: string } }) => {
        reportUrl(e?.nativeEvent?.url);
        props.onLoadStart?.(e);
      },
      [props.onLoadStart, reportUrl],
    );
    const onNavigationStateChange = React.useCallback(
      (state: NavigationStateLike) => {
        reportUrl(state.url);
        props.onNavigationStateChange?.(state);
      },
      [props.onNavigationStateChange, reportUrl],
    );

    return React.createElement(Wrapped, {
      ...props,
      onLoadStart,
      onNavigationStateChange,
    });
  };
}

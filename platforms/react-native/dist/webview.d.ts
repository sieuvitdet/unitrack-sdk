import React from 'react';
interface NavigationStateLike {
    url?: string;
}
interface WebViewLikeProps {
    onLoadStart?: (e: {
        nativeEvent?: {
            url?: string;
        };
    }) => void;
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
export declare function withUniTrackWebView<P extends WebViewLikeProps>(Wrapped: React.ComponentType<P>): React.ComponentType<P>;
export {};
//# sourceMappingURL=webview.d.ts.map
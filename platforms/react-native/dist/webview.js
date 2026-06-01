"use strict";
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.withUniTrackWebView = withUniTrackWebView;
const react_1 = __importDefault(require("react"));
const index_1 = __importDefault(require("./index"));
/**
 * Wrap a WebView component so the SDK sees URL changes.
 *
 * - First load (or host change) → `webview_open` with the URL.
 * - Same-host navigations → `webview_navigate`.
 *
 * Existing onLoadStart / onNavigationStateChange handlers on the wrapped
 * component still fire — we chain instead of replacing.
 */
function withUniTrackWebView(Wrapped) {
    return function UniTrackedWebView(props) {
        // Per-instance ref — kept in a ref so component re-renders don't reset it.
        const firstHostRef = react_1.default.useRef(null);
        const reportUrl = react_1.default.useCallback((url) => {
            if (!url)
                return;
            let host = null;
            try {
                host = new URL(url).host;
            }
            catch (_) { /* malformed — skip host */ }
            const current = firstHostRef.current;
            if (current === null || current !== host) {
                firstHostRef.current = host;
                index_1.default.trackWebViewOpen(url);
            }
            else {
                index_1.default.track('webview_navigate', { url });
            }
        }, []);
        const onLoadStart = react_1.default.useCallback((e) => {
            var _a, _b;
            reportUrl((_a = e === null || e === void 0 ? void 0 : e.nativeEvent) === null || _a === void 0 ? void 0 : _a.url);
            (_b = props.onLoadStart) === null || _b === void 0 ? void 0 : _b.call(props, e);
        }, [props.onLoadStart, reportUrl]);
        const onNavigationStateChange = react_1.default.useCallback((state) => {
            var _a;
            reportUrl(state.url);
            (_a = props.onNavigationStateChange) === null || _a === void 0 ? void 0 : _a.call(props, state);
        }, [props.onNavigationStateChange, reportUrl]);
        return react_1.default.createElement(Wrapped, {
            ...props,
            onLoadStart,
            onNavigationStateChange,
        });
    };
}
//# sourceMappingURL=webview.js.map
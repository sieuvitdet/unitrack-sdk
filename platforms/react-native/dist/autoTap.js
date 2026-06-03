"use strict";
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.UniTrackTapBoundary = exports.tapState = void 0;
const react_1 = __importDefault(require("react"));
const react_native_1 = require("react-native");
const index_1 = __importDefault(require("./index"));
const tapState_1 = require("./tapState");
var tapState_2 = require("./tapState");
Object.defineProperty(exports, "tapState", { enumerable: true, get: function () { return tapState_2.tapState; } });
/** Walk up the React Fiber tree from the touched node to find a good name. */
function resolveName(fiber) {
    var _a, _b, _c, _d, _e, _f;
    let node = fiber;
    let testID;
    let label;
    let text;
    let componentName;
    let pressableType;
    let depth = 0;
    while (node && depth < 40) {
        const props = (_a = node.memoizedProps) !== null && _a !== void 0 ? _a : node.pendingProps;
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
                pressableType = (_b = elementName(node)) !== null && _b !== void 0 ? _b : 'Pressable';
            }
        }
        if (!componentName)
            componentName = elementName(node);
        node = node.return;
        depth++;
    }
    const name = (_e = (_d = (_c = testID !== null && testID !== void 0 ? testID : label) !== null && _c !== void 0 ? _c : text) !== null && _d !== void 0 ? _d : pressableType) !== null && _e !== void 0 ? _e : componentName;
    if (!name)
        return null;
    return { name, type: (_f = pressableType !== null && pressableType !== void 0 ? pressableType : componentName) !== null && _f !== void 0 ? _f : 'unknown' };
}
function elementName(fiber) {
    const t = fiber === null || fiber === void 0 ? void 0 : fiber.type;
    if (!t)
        return undefined;
    if (typeof t === 'string')
        return t; // host component, e.g. 'RCTView'
    return t.displayName || t.name || undefined;
}
/**
 * Bucket a tap by component name. RN strips reflection too, so we match
 * displayName prefixes against the standard library. The native modules
 * (`RCTView`, `RCTText` …) and the standard touchables come from
 * react-native; everything else is app code. Helps the portal split
 * "tapped a TouchableOpacity in the framework" vs "tapped MyCustomButton".
 */
function classifyRNComponent(type) {
    if (!type)
        return 'unknown';
    // Native host components prefixed with RCT-.
    if (type.startsWith('RCT'))
        return 'react-native';
    const rnLibPrefixes = [
        'Touchable', 'Pressable', 'Button', 'Text', 'View', 'ScrollView',
        'FlatList', 'SectionList', 'Image', 'Switch', 'Slider', 'Modal',
    ];
    for (const p of rnLibPrefixes)
        if (type.startsWith(p))
            return 'react-native';
    return 'app';
}
/**
 * Wrap your app once with this. It uses a capture-phase responder so it observes
 * every touch without interfering with the components' own press handling.
 */
class UniTrackTapBoundary extends react_1.default.Component {
    constructor() {
        super(...arguments);
        this.lastKey = '';
        this.lastAt = 0;
        this.onCapture = (e) => {
            var _a, _b;
            try {
                const target = (_a = e === null || e === void 0 ? void 0 : e._targetInst) !== null && _a !== void 0 ? _a : (_b = e === null || e === void 0 ? void 0 : e.target) === null || _b === void 0 ? void 0 : _b._internalFiberInstanceHandleDEV;
                const resolved = target ? resolveName(target) : null;
                if (resolved) {
                    const now = Date.now();
                    // Debounce identical rapid taps.
                    if (!(resolved.name === this.lastKey && now - this.lastAt < 250)) {
                        this.lastKey = resolved.name;
                        this.lastAt = now;
                        const screen = tapState_1.tapState.currentScreen;
                        tapState_1.tapState.last = { element: resolved.name, screen, at: now };
                        // Classify the source component by name. Same prefix-allowlist
                        // shape as Android/Flutter — RN has no module-of-origin reflection
                        // either, so we infer from the displayName/name.
                        const pkg = classifyRNComponent(resolved.type);
                        // Use the convention name "click" — matches iOS / Android / Flutter
                        // swizzlers. Snowplow maps via portal `event_names.click` (default
                        // → `event_click`) so the schema URI is uniform across platforms.
                        index_1.default.track('click', {
                            // `element_key` is the field the portal (session tree + heatmap) and
                            // the iOS/Android native tap capture use — send it so RN taps line up
                            // with the other platforms. `element` kept for backwards-compat.
                            element_key: resolved.name,
                            element: resolved.name,
                            element_type: resolved.type,
                            class_name: resolved.type,
                            framework: 'react-native',
                            package: pkg,
                            screen,
                        });
                    }
                }
            }
            catch {
                // Never let tracking break touch handling.
            }
            return false; // do not become the responder; let the real target handle it
        };
    }
    render() {
        return (react_1.default.createElement(react_native_1.View, { style: { flex: 1 }, onStartShouldSetResponderCapture: this.onCapture }, this.props.children));
    }
}
exports.UniTrackTapBoundary = UniTrackTapBoundary;
exports.default = UniTrackTapBoundary;
//# sourceMappingURL=autoTap.js.map
"use strict";
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = createNavigationTracker;
const index_1 = __importDefault(require("./index"));
let currentRouteName;
function getActiveRouteName(state) {
    if (!state || typeof state.index !== 'number')
        return undefined;
    const route = state.routes[state.index];
    if (route === null || route === void 0 ? void 0 : route.state)
        return getActiveRouteName(route.state);
    return route === null || route === void 0 ? void 0 : route.name;
}
function createNavigationTracker() {
    const ref = { current: null };
    return {
        ref,
        onReady: () => {
            var _a, _b, _c;
            const name = (_c = (_b = (_a = ref.current) === null || _a === void 0 ? void 0 : _a.getCurrentRoute) === null || _b === void 0 ? void 0 : _b.call(_a)) === null || _c === void 0 ? void 0 : _c.name;
            if (name) {
                currentRouteName = name;
                index_1.default.setScreen(name);
            }
        },
        onStateChange: (state) => {
            const name = getActiveRouteName(state);
            if (name && name !== currentRouteName) {
                currentRouteName = name;
                index_1.default.setScreen(name);
            }
        },
    };
}
//# sourceMappingURL=navigation.js.map
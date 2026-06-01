"use strict";
// UniTrack screen wireframe snapshot for React Native.
//
// RN doesn't give the JS side a way to walk the on-screen view tree
// directly — UIManager.measure is async per-handle and bridge-heavy. The
// pragmatic path is the React Fiber tree: app code passes the root
// component's ref (or React's debug owner), we walk the Fiber tree and
// emit `screen_layout` with the JS component types + memoised props.
//
// Wire from the app's nav listener after a screen transition:
//
//     import { snapshotCurrentScreen } from 'unitrack/wireframe';
//     onScreenChange: () => snapshotCurrentScreen(rootRef.current),
//
// Without a host ref the helper is a no-op (we don't have a global root
// hook in RN). Most apps already hold a NavigationContainer ref for
// react-navigation, which is the same thing.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.setMaxNodes = setMaxNodes;
exports.snapshotCurrentScreen = snapshotCurrentScreen;
// RN doesn't ship a gzip in Hermes and pulling fflate just for the wireframe
// is too much weight. The portal accepts both shapes: `tree_b64gz` (gzipped)
// or `tree_json` (raw). RN sends raw — payload is 5–20 KB per snapshot which
// is acceptable; server can re-gzip on write if storage matters.
const index_1 = __importDefault(require("./index"));
let maxNodes = 500;
function setMaxNodes(n) { maxNodes = n; }
/**
 * Walk the React Fiber tree rooted at [ref] and emit a `screen_layout`
 * event. The fiber walk is synchronous + cheap (no UIManager round-trip)
 * but doesn't carry on-screen coordinates — x/y/w/h are 0 here because
 * Fiber holds layout only for hosts post-render and reading them
 * cross-platform would require a UIManager.measure call per node. The
 * portal renderer treats 0-sized nodes as "size unknown" and falls back
 * to a flow layout.
 */
function snapshotCurrentScreen(ref) {
    // ref may be a component instance, a HostRef, or a function-component
    // ref returned by useRef. Walk the React Fiber tree from whichever.
    const fiber = getFiberFromRef(ref);
    if (!fiber)
        return;
    const counter = { value: 0 };
    const root = walk(fiber, counter);
    if (!root)
        return;
    const truncated = counter.value >= maxNodes;
    try {
        index_1.default.track('screen_layout', {
            tree_json: JSON.stringify(root),
            node_count: counter.value,
            truncated,
            framework: 'react-native',
        });
    }
    catch (_) { /* never fail the app — drop the snapshot */ }
}
function getFiberFromRef(ref) {
    if (!ref)
        return null;
    // Class component instance: _reactInternalFiber (legacy) / _reactInternals.
    return ref._reactInternals
        || ref._reactInternalFiber
        || (ref.stateNode && (ref.stateNode._reactInternals || ref.stateNode._reactInternalFiber))
        || ref;
}
function walk(fiber, counter) {
    if (!fiber)
        return null;
    if (counter.value >= maxNodes)
        return null;
    counter.value++;
    const type = fiberTypeName(fiber);
    const node = {
        id: counter.value, type, x: 0, y: 0, w: 0, h: 0,
    };
    // For text-like host nodes, the first child fiber often is the text
    // string itself. Surface short strings as `text`.
    const props = fiber.memoizedProps || {};
    if (typeof props.children === 'string' && props.children.length > 0) {
        node.text = trim(props.children);
    }
    const children = [];
    let child = fiber.child;
    while (child) {
        if (counter.value >= maxNodes)
            break;
        const c = walk(child, counter);
        if (c)
            children.push(c);
        child = child.sibling;
    }
    if (children.length > 0)
        node.children = children;
    return node;
}
function fiberTypeName(fiber) {
    const t = fiber.type;
    if (!t)
        return 'Unknown';
    if (typeof t === 'string')
        return t;
    return t.displayName || t.name || 'Anonymous';
}
function trim(s) {
    return s.length > 64 ? s.substring(0, 63) + '…' : s;
}
//# sourceMappingURL=wireframe.js.map
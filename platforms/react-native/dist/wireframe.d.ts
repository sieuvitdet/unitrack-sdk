export declare function setMaxNodes(n: number): void;
/**
 * Walk the React Fiber tree rooted at [ref] and emit a `screen_layout`
 * event. The fiber walk is synchronous + cheap (no UIManager round-trip)
 * but doesn't carry on-screen coordinates — x/y/w/h are 0 here because
 * Fiber holds layout only for hosts post-render and reading them
 * cross-platform would require a UIManager.measure call per node. The
 * portal renderer treats 0-sized nodes as "size unknown" and falls back
 * to a flow layout.
 */
export declare function snapshotCurrentScreen(ref: any): void;
//# sourceMappingURL=wireframe.d.ts.map
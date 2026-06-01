import React from 'react';
export { tapState } from './tapState';
export type { LastTap } from './tapState';
interface Props {
    children: React.ReactNode;
}
/**
 * Wrap your app once with this. It uses a capture-phase responder so it observes
 * every touch without interfering with the components' own press handling.
 */
export declare class UniTrackTapBoundary extends React.Component<Props> {
    private lastKey;
    private lastAt;
    private onCapture;
    render(): React.JSX.Element;
}
export default UniTrackTapBoundary;
//# sourceMappingURL=autoTap.d.ts.map
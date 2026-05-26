// Shared, dependency-free tap state — mirrored from the tap boundary onto
// network events. Kept in its own module to avoid an index <-> autoTap cycle.

export interface LastTap {
  element: string;
  screen?: string;
  at: number;
}

export const tapState: { last?: LastTap; currentScreen?: string } = {};

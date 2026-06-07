// Ambient declarations for peer dependencies — keeps `tsc --noEmit` clean
// when this package is checked in isolation (without the consumer app's
// node_modules tree). At runtime the real modules come from the host app.

declare module '@unitrack/react-native' {
  export type EventProperties = Record<string, unknown>;
  export interface AnalyticsProvider {
    initialize(): void | Promise<void>;
    track(name: string, properties: EventProperties): void;
    setUser(userId: string | null, traits: EventProperties): void;
    setScreen(name: string): void;
  }
}

declare module '@snowplow/react-native-tracker';

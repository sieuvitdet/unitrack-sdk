// AnalyticsProvider — extension point for forwarding UniTrack events to
// third-party analytics SDKs (Snowplow, Firebase, …).
//
// The core '@unitrack/react-native' package depends on NOTHING third-party. A
// provider lives in its own package (@unitrack/snowplow, @unitrack/firebase)
// that pulls in the heavy SDK, implements this interface, and is registered by
// the app:
//
//   UniTrack.addProvider(new SnowplowProvider({ endpoint, appId }));
//   UniTrack.addProvider(new FirebaseProvider());
//   await UniTrack.initialize(apiKey);
//
// Every event UniTrack captures (manual track() and all auto-capture) is
// forwarded to each registered provider.

export type EventProperties = Record<string, unknown>;

export interface AnalyticsProvider {
  /** Bring up the underlying SDK. Called once when UniTrack initializes (or
   *  immediately if registered after initialize()). */
  initialize(): void | Promise<void>;

  /** Forward one event. */
  track(name: string, properties: EventProperties): void;

  /** Sync the identified user. `userId === null` means logged out. */
  setUser(userId: string | null, traits: EventProperties): void;

  /** The current screen changed. */
  setScreen(name: string): void;
}

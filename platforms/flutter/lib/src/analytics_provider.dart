// AnalyticsProvider — the extension point for forwarding UniTrack events to
// third-party analytics SDKs (Snowplow, Firebase, …).
//
// The core `unitrack` package depends on NOTHING third-party. A provider lives
// in its own package (e.g. `unitrack_snowplow`, `unitrack_firebase`) that pulls
// in the heavy SDK, implements this interface, and is registered by the app:
//
//   UniTrack.instance.addProvider(SnowplowProvider(endpoint: ..., appId: ...));
//   UniTrack.instance.addProvider(FirebaseProvider());
//   await UniTrack.instance.initialize(apiKey);
//
// Every event UniTrack captures (manual track() and all auto-capture: tap,
// screen_view, network, crash, notification) is forwarded to each registered
// provider — they all funnel through UniTrack.track()/setScreen()/identify().
abstract class AnalyticsProvider {
  /// Bring up the underlying SDK. Called once when UniTrack initializes (or
  /// immediately if the provider is registered after initialize()).
  Future<void> init();

  /// Forward one event. [name] is the UniTrack event name, [properties] its
  /// merged properties (may include device/screen fields).
  void track(String name, Map<String, Object?> properties);

  /// Sync the identified user. [userId] null means "logged out".
  void setUser(String? userId, Map<String, Object?> traits);

  /// The current screen changed.
  void setScreen(String name);
}

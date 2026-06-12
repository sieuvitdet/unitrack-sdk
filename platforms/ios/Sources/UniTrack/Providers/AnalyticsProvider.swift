// AnalyticsProvider — extension point for forwarding UniTrack events to
// third-party analytics SDKs (Snowplow, Firebase, …).
//
// The core UniTrack pod depends on NOTHING third-party. A provider lives in its
// own pod (UniTrackSnowplow, UniTrackFirebase) that pulls in the heavy SDK,
// conforms to this protocol, and is registered by the app:
//
//   UniTrack.addProvider(SnowplowProvider(endpoint: ..., appId: ...))
//   UniTrack.addProvider(FirebaseProvider())
//   UniTrack.initialize(apiKey: ...)
//
// Every event UniTrack captures (manual track() and all auto-capture) is
// forwarded to each registered provider — they all funnel through
// UniTrack.track()/setScreen()/identify().
import Foundation

public protocol AnalyticsProvider: AnyObject {
    /// Bring up the underlying SDK. Called once when UniTrack initializes (or
    /// immediately if the provider is registered after initialize()).
    func initializeProvider()

    /// Forward one event.
    func track(_ name: String, _ properties: [String: Any])

    /// Sync the identified user. `userId == nil` means logged out.
    func setUser(_ userId: String?, _ traits: [String: Any])

    /// The current screen changed.
    func setScreen(_ name: String)
}

/// Alias for `AnalyticsProvider`. Use this when integrating UniTrack into an
/// app that already declares a top-level `protocol AnalyticsProvider` of its
/// own (vd FPT Life's FLifeTracker layer) — Swift can't disambiguate
/// `UniTrack.AnalyticsProvider` because the module name `UniTrack` collides
/// with the SDK facade `class UniTrack`. Conform to this typealias instead:
///
///     final class MyFirebaseProvider: UniTrackAnalyticsProvider { ... }
///
/// Identical semantics — same 4 methods, same dispatch. Existing code that
/// already conforms to `AnalyticsProvider` keeps working unchanged.
public typealias UniTrackAnalyticsProvider = AnalyticsProvider

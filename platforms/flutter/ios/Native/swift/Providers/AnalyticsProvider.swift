// AnalyticsProvider — extension point for forwarding UniTrack events to
// third-party analytics SDKs (Snowplow, Firebase, …) or custom HTTP backends
// (Kibana / ELK / FPT internal).
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

/// Result of forwarding ONE event to a provider. Drives the offline ack queue:
///
///   - .success → drop event from queue for this provider
///   - .retry   → keep event, exponential backoff, try again
///   - .drop    → permanent failure (vd HTTP 4xx, payload sai schema) — give up
///
/// Providers that don't care about ack semantics (vd Snowplow/Firebase SDK lo
/// retry internally) can keep returning .success unconditionally — that's the
/// default. Custom providers that ship over HTTP and want UniTrack to handle
/// offline retry should return .retry when network/5xx fails.
public enum ProviderResult {
    case success
    case retry
    case drop
}

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

public extension AnalyticsProvider {
    /// Ack-aware delivery. Default impl calls `track` and returns `.success` —
    /// existing providers (Snowplow, Firebase) keep working unchanged because
    /// their own SDKs handle retry internally.
    ///
    /// Custom HTTP providers (vd `UniTrackHttpProvider`) override this to
    /// return `.retry` on network/5xx so UniTrack PendingQueue retries with
    /// exponential backoff, `.drop` on 4xx to avoid looping on schema errors.
    func send(_ name: String, _ properties: [String: Any]) -> ProviderResult {
        track(name, properties)
        return .success
    }

    /// Stable provider id used as the column key in the per-provider ack
    /// bitmask. Two providers with the same id share a slot — fine if they're
    /// fungible (vd 2 Snowplow collectors in HA pair). Default: type name.
    var providerId: String {
        String(describing: type(of: self))
    }
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

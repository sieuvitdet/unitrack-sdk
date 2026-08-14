package com.unitrack.sdk.providers

import android.app.Application

/**
 * Result of forwarding ONE event to a provider. Drives the offline ack queue:
 *
 *   - SUCCESS → drop event from queue for this provider
 *   - RETRY   → keep event, exponential backoff, try again
 *   - DROP    → permanent failure (vd HTTP 4xx, payload sai schema) — give up
 *
 * Providers that don't care about ack semantics (vd Snowplow/Firebase SDK lo
 * retry nội bộ) can keep returning SUCCESS unconditionally — that's the
 * default. Custom providers that ship over HTTP and want UniTrack to lo
 * offline retry hộ should return RETRY when network/5xx fails.
 */
enum class ProviderResult {
    SUCCESS,
    RETRY,
    DROP,
}

/**
 * Extension point for forwarding UniTrack events to third-party analytics SDKs
 * (Snowplow, Firebase, …) or custom HTTP backends (Kibana / ELK / FPT nội bộ).
 *
 * The core `unitrack` module depends on NOTHING third-party. A provider lives
 * in its own module (e.g. `unitrack-snowplow`) that pulls in the heavy SDK,
 * implements this interface, and is registered by the app. Firebase Analytics
 * mirror sẵn có qua `UniTrack.attachFirebaseAdapter(app)` (reflection-based).
 *
 *     UniTrack.addProvider(SnowplowProvider(endpoint = ..., appId = ...))
 *     UniTrack.attachFirebaseAdapter(app)   // built-in, không cần module riêng
 *     UniTrack.initialize(app, UniTrackConfig(apiKey = ...))
 *
 * Every event UniTrack captures (manual track() and all auto-capture) is
 * forwarded to each registered provider.
 */
interface AnalyticsProvider {
    /** Bring up the underlying SDK. Called once when UniTrack initializes (or
     *  immediately if registered after initialize()). */
    fun initialize(app: Application)

    /** Forward one event. */
    fun track(name: String, properties: Map<String, Any?>)

    /** Sync the identified user. [userId] null means logged out. */
    fun setUser(userId: String?, traits: Map<String, Any?>)

    /** The current screen changed. */
    fun setScreen(name: String)

    /**
     * The current screen changed, with the screen it came from.
     *
     * UniTrack owns the screen state machine (lastScreen + the isSameScreen
     * dup guard), so it is the single source of truth for what the previous
     * screen was. A provider deriving its own previous-screen state drifts
     * from UniTrack's whenever UniTrack suppresses a transition — vd bg→fg
     * resume, where Snowplow's builtin ScreenView would stamp
     * previousName == name because its internal state never saw the exit.
     *
     * Default impl drops [previous] and calls [setScreen] so existing
     * providers keep compiling; providers that can carry it should override.
     */
    fun setScreen(name: String, previous: String?) = setScreen(name)

    /**
     * Ack-aware delivery. Default impl calls [track] and returns SUCCESS —
     * existing providers (Snowplow, Firebase) keep working unchanged because
     * their own SDKs handle retry internally.
     *
     * Custom HTTP providers (vd UniTrackHttpProvider) override this to return
     * RETRY on network/5xx so UniTrack PendingQueue retries with exponential
     * backoff, DROP on 4xx so we don't loop forever on schema errors.
     */
    fun send(name: String, properties: Map<String, Any?>): ProviderResult {
        track(name, properties)
        return ProviderResult.SUCCESS
    }

    /**
     * Stable provider id used as the column key in the per-provider ack
     * bitmask. Two providers with the same id share a slot — fine if they're
     * fungible (vd 2 Snowplow collectors in HA pair). Default: class name.
     */
    val providerId: String
        get() = this::class.java.simpleName
}

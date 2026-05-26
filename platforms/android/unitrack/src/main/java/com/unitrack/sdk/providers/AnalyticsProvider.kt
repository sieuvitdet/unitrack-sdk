package com.unitrack.sdk.providers

import android.app.Application

/**
 * Extension point for forwarding UniTrack events to third-party analytics SDKs
 * (Snowplow, Firebase, …).
 *
 * The core `unitrack` module depends on NOTHING third-party. A provider lives
 * in its own module (`unitrack-snowplow`, `unitrack-firebase`) that pulls in the
 * heavy SDK, implements this interface, and is registered by the app:
 *
 *     UniTrack.addProvider(SnowplowProvider(endpoint = ..., appId = ...))
 *     UniTrack.addProvider(FirebaseProvider())
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
}

// CameraAnalytics.swift
//
// Maps the camera/CCTV event taxonomy onto UniTrack. UniTrack auto-captures
// screen_view, tap, network_request, app_foreground/background, app_start and
// crash with ZERO code. The domain-specific camera events below are explicit
// `track()` calls — analytics SDKs can't infer "live stream started" from UI.
//
// This file is the single tracking surface for the whole app; the view
// controllers call these semantic methods so the taxonomy stays in one place.

import Foundation
import UIKit
import UniTrack
import UniTrackSnowplow   // Snowplow provider (Swift Package product)
import UniTrackFirebase   // Firebase provider (Swift Package product)

enum CameraAnalytics {

    // The ONLY hardcoded values: the bootstrap api_key + where to fetch config.
    // Everything else (ingest endpoint, Snowplow, Firebase, super-properties,
    // SDK flags) comes from the portal's remote config so it can change without
    // rebuilding the app.
    static let apiKey   = "utk_6yC71Z4ZgPSIysijkh-ACf9g"
    static let configURL = "https://mobix.asia/event-tracking-mobile/config"

    // Kept so super/user properties can be updated at runtime (e.g. after login).
    static var firebase: FirebaseProvider?

    /// Update Firebase custom data at runtime (e.g. once the user logs in).
    static func updateFirebaseContext(userId: String, plan: String, region: String) {
        firebase?.setSuperProperty("user_id", userId)
        firebase?.setUserProperty("subscription_plan", plan)
        firebase?.setUserProperty("region", region)
    }

    /// Fetch remote config from the portal, then start tracking. Never blocks
    /// launch: on portal failure it uses the cached/built-in default config.
    static func bootstrap(_ done: @escaping () -> Void) {
        UniTrackRemoteConfig.fetch(apiKey: apiKey, configURL: configURL, timeout: 3) { cfg in
            DispatchQueue.main.async {
                start(remote: cfg)
                done()
            }
        }
    }

    static var snowplow: SnowplowProvider?

    /// Build UniTrack.Config + providers entirely from the fetched remote config.
    static func start(remote cfg: UniTrackRemoteConfig) {
        // Snowplow — only if the portal enabled it.
        if cfg.snowplow.enabled == true, let spEndpoint = cfg.snowplow.endpoint,
           let appId = cfg.snowplow.appId, !spEndpoint.isEmpty {
            let o = cfg.snowplow.options ?? [:]
            let sp = SnowplowProvider(
                endpoint: spEndpoint,
                appId: appId,
                namespace: cfg.snowplow.namespace ?? "UniTrack",
                userContext: cfg.snowplow.userContext?.unwrapped(),
                userContextSchema: cfg.snowplow.userContextSchema,
                schemas: cfg.snowplow.schemas ?? [:],
                options: SnowplowOptions(
                    base64Encoding:              o["base64Encoding"] ?? true,
                    platformContext:             o["platformContext"] ?? true,
                    applicationContext:          o["applicationContext"] ?? true,
                    sessionContext:              o["sessionContext"] ?? true,
                    screenContext:               o["screenContext"] ?? true,
                    lifecycleAutotracking:       o["lifecycleAutotracking"] ?? true,
                    screenEngagementAutotracking: o["screenEngagementAutotracking"] ?? true,
                    // OFF: UniTrack already emits screen_view; Snowplow's own
                    // ScreenView autotracking would double-count each screen
                    // (once stripped by UniTrack, once raw "MyApp.VC" by Snowplow).
                    screenViewAutotracking:      o["screenViewAutotracking"] ?? false,
                    exceptionAutotracking:       o["exceptionAutotracking"] ?? true,
                    installAutotracking:         o["installAutotracking"] ?? true
                ),
                // Convention layer config — the tracking* helpers build
                //   iglu:<igluVendor>/<event_name>/jsonschema/<defaultVersion>
                // at each call site. Both come from the portal so a schema
                // bump (1-0-0 → 1-1-0) doesn't require an app rebuild.
                igluVendor:     cfg.snowplow.igluVendor,
                defaultVersion: cfg.snowplow.defaultVersion ?? "1-0-0",
                // Convention kind → event name (click / result / screen_view
                // / crash / api). Lets a 3rd-party integrator re-skin the
                // helpers under their own taxonomy (e.g. "fss_event_click")
                // from the portal without touching SDK code.
                eventNames:     cfg.snowplow.eventNames ?? [:]
            )
            // Blueprint engine + device blob + globals — same pattern Flutter
            // uses so the camera demo can resolve `track("camera_stream_started")`
            // to a Snowplow self-describing event without any per-event schema
            // wiring in app code.
            sp.applyBlueprintConfig(
                blueprints: cfg.snowplowBlueprints,
                entities:   cfg.snowplowEntities,
                eventBlueprintMap: cfg.snowplowEventBlueprintMap,
            )
            let info = Bundle.main.infoDictionary ?? [:]
            sp.setDeviceBlob([
                "platform":    "ios",
                "app_bundle":  (info["CFBundleIdentifier"] as? String) ?? "",
                "app_version": (info["CFBundleShortVersionString"] as? String) ?? "",
                "device_name": UIDevice.current.name,
            ])
            sp.setGlobalContext([
                "user":       ["user_id": "demo_user_42"],
                "session_id": UUID().uuidString,
                "flavor":     "staging",
            ])
            UniTrack.addProvider(sp)
            snowplow = sp
        }

        // Firebase — only if enabled; configured at RUNTIME from portal values
        // (no GoogleService-Info.plist in the bundle).
        if cfg.firebase.enabled == true {
            var fbOptions: FirebaseProvider.Options?
            if let opt = cfg.firebase.options, let appID = opt.appId, let sender = opt.gcmSenderId {
                fbOptions = FirebaseProvider.Options(
                    googleAppID: appID, gcmSenderID: sender,
                    apiKey: opt.apiKey, projectID: opt.projectId,
                    bundleID: opt.bundleId, storageBucket: opt.storageBucket)
            }
            firebase = FirebaseProvider(
                firebaseOptions: fbOptions,
                portalEndpoint: cfg.endpoint,
                portalApiKey: apiKey,
                superProperties: cfg.firebase.superProperties?.unwrapped() ?? [:],
                userProperties: cfg.firebase.userProperties?.unwrapped() ?? [:]
            )
            UniTrack.addProvider(firebase!)
        }

        // Phase 2: rewrite rules from the portal. The SDK turns auto-captured
        // events (tap/screen/network) into business events by name — so adding
        // a NEW tracked moment for an existing screen/button needs no app code,
        // just a rule on the portal.
        UniTrack.setEventRules(cfg.toEventRules())

        // Core SDK config from the portal.
        let s = cfg.sdkConfig
        var config = UniTrack.Config()
        config.endpoint        = cfg.endpoint
        config.batchSize       = s.batchSize ?? 10
        config.flushIntervalMs = s.flushIntervalMs ?? 3000
        config.samplingRate    = s.samplingRate ?? 1.0
        config.autoCapture     = s.autoCapture ?? true
        config.trackScreens    = s.trackScreens ?? true
        config.trackTaps       = s.trackTaps ?? true
        config.trackNetwork    = s.trackNetwork ?? true
        config.logLevel        = (s.logLevel == "debug") ? .debug : .warn
        // Wire taxonomy overrides — sheet says screen_viewed/screen_exited,
        // core defaults to screen_start/screen_end.
        config.screenStartEvent = s.screenStartEvent
        config.screenEndEvent   = s.screenEndEvent
        UniTrack.initialize(apiKey: apiKey, config: config)
    }

    // Sheet field naming notes:
    //   • camera_serial: B2C serial (cam_living_room etc.)
    //   • camera_id:     B2B VMS id (used in vms_* events)
    //   • watch_sec:     ms/1000 rounded — used in *_ended / *_played
    //   • action:        "play" | "pause" | "stop" for stream_paused / buffering
    //   • view_mode:     "single" | "grid" — UI display mode at the time
    //   • grid_size:     count of camera tiles visible
    //
    // session_id / user_id / app_id / platform fields are filled by the
    // blueprint `user_context` entity, so each helper here only carries the
    // event-specific props (the schema fields outside that entity).

    // ── Session lifecycle (#1, #2) ───────────────────────────────────────────
    private static var sessionIndex = 0
    static func sessionStarted() {
        sessionIndex += 1
        UniTrack.track("session_started",
                       properties: ["session_index": sessionIndex, "source": "app_open"])
    }
    static func sessionEnded(reason: String) {
        UniTrack.track("session_ended",
                       properties: ["reason": reason])
    }

    // ── Navigation (#3, #4, #26) — fully auto by SDK swizzler.

    // ── Camera live streaming B2C (#5, #6, #7) ───────────────────────────────
    static func streamStarted(cameraSerial: String, channel: Int = 0,
                              viewMode: String = "single", gridSize: Int = 1) {
        UniTrack.track("camera_stream_started", properties: [
            "camera_serial": cameraSerial,
            "channel":       channel,
            "view_mode":     viewMode,
            "grid_size":     gridSize,
        ])
        // Snowplow leg: entering the live stream screen also emits a convention
        // event_screen_view so Snowplow funnel queries can group by screen name
        // without parsing the camera_stream_started payload. Two events on the
        // wire (one UniTrack, one Snowplow self-describing) — portal dedupes
        // by event_id when displayed.
        snowplow?.trackingScreenView(
            screenName: "LiveStreamVC",
            fromScreen: "CameraListVC",
            data: ["camera_serial": cameraSerial, "view_mode": viewMode]
        )
    }
    static func streamEnded(cameraSerial: String, watchSec: Int,
                            viewMode: String = "single") {
        UniTrack.track("camera_stream_ended", properties: [
            "camera_serial": cameraSerial,
            "watch_sec":     watchSec,
            "view_mode":     viewMode,
        ])
    }
    static func streamPaused(cameraSerial: String) {
        UniTrack.track("camera_stream_paused",
                       properties: ["camera_serial": cameraSerial])
    }

    // ── Camera events & playback B2C (#8, #9, #10) ───────────────────────────
    static func eventViewed(cameraSerial: String, channel: Int = 0) {
        UniTrack.track("camera_event_viewed", properties: [
            "camera_serial": cameraSerial, "channel": channel,
        ])
    }
    static func playbackStarted(cameraSerial: String, channel: Int = 0) {
        UniTrack.track("camera_playback_started", properties: [
            "camera_serial": cameraSerial, "channel": channel,
        ])
    }
    static func playbackEnded(cameraSerial: String, watchSec: Int) {
        UniTrack.track("camera_playback_ended", properties: [
            "camera_serial": cameraSerial, "watch_sec": watchSec,
        ])
    }

    // ── Notifications (#11, #12, #13, #14) ───────────────────────────────────
    static func notificationPermissionChecked(granted: Bool) {
        UniTrack.track("notification_permission_checked", properties: [
            "permission_status": granted ? "granted" : "denied",
        ])
    }
    static func notificationSent(cameraSerial: String, notificationType: String) {
        UniTrack.track("camera_notification_sent", properties: [
            "camera_serial": cameraSerial, "notification_type": notificationType,
        ])
    }
    static func notificationDelivered(cameraSerial: String, notificationType: String) {
        UniTrack.track("camera_notification_delivered", properties: [
            "camera_serial": cameraSerial, "notification_type": notificationType,
        ])
    }
    static func notificationClicked(cameraSerial: String,
                                    notificationLabel: String) {
        UniTrack.track("camera_notification_clicked", properties: [
            "camera_serial":      cameraSerial,
            "notification_label": notificationLabel,
        ])
    }

    // ── Camera settings B2C (#15) ────────────────────────────────────────────
    static func aiFeatureToggled(cameraSerial: String,
                                 aiFeatureCode: String, on: Bool) {
        UniTrack.track("camera_ai_feature_toggled", properties: [
            "camera_serial":   cameraSerial,
            "ai_feature_code": aiFeatureCode,
            "action":          on ? "on" : "off",
        ])
        // Snowplow leg via the escape-hatch helper: this event name isn't
        // (yet) a first-class tracking* helper, but the convention rule still
        // applies — schema is iglu:<vendor>/camera_ai_feature_toggled/jsonschema/<version>.
        // Replace this with a typed helper if it earns one later.
        snowplow?.trackingCustomEvent(
            "camera_ai_feature_toggled",
            data: [
                "camera_serial":   cameraSerial,
                "ai_feature_code": aiFeatureCode,
                "action":          on ? "on" : "off",
            ]
        )
    }

    // ── VMS B2B (#16, #17, #18, #19) ─────────────────────────────────────────
    static func vmsCameraConnected(cameraId: String, channelCount: Int = 1,
                                   viewMode: String = "grid", gridSize: Int = 4) {
        UniTrack.track("vms_camera_connected", properties: [
            "camera_id":     cameraId,
            "channel_count": channelCount,
            "view_mode":     viewMode,
            "grid_size":     gridSize,
        ])
    }
    static func vmsCameraDisconnected(cameraId: String, watchSec: Int,
                                      viewMode: String = "grid") {
        UniTrack.track("vms_camera_disconnected", properties: [
            "camera_id": cameraId, "watch_sec": watchSec, "view_mode": viewMode,
        ])
    }
    static func vmsRecordingPlayed(cameraId: String, watchSec: Int) {
        UniTrack.track("vms_recording_played", properties: [
            "camera_id": cameraId, "watch_sec": watchSec,
        ])
    }
    static func vmsAlertViewed(cameraId: String, alertType: String) {
        UniTrack.track("vms_alert_viewed", properties: [
            "camera_id": cameraId, "alert_type": alertType,
        ])
    }

    // ── Camera sharing B2C (#20, #21) ────────────────────────────────────────
    static func cameraShared(ownerId: String, cameraSerial: String, sharerId: String) {
        UniTrack.track("camera_shared", properties: [
            "owner_id": ownerId, "camera_serial": cameraSerial, "sharer_id": sharerId,
        ])
    }
    static func cameraShareRevoked(ownerId: String, cameraSerial: String, sharerId: String) {
        UniTrack.track("camera_share_revoked", properties: [
            "owner_id": ownerId, "camera_serial": cameraSerial, "sharer_id": sharerId,
        ])
    }

    // ── Pairing & registration (#22, #23, #24, #25) ──────────────────────────
    static func pairingStarted() {
        UniTrack.track("camera_pairing_started", properties: [:])
    }
    static func pairingCompleted(cameraSerial: String) {
        UniTrack.track("camera_pairing_completed", properties: [
            "camera_serial": cameraSerial,
        ])
        // Snowplow leg: pairing completion is a successful action outcome,
        // so go through the convention "event_result" helper. Backend funnel
        // can then ask "which actions succeed/fail" without name-mapping.
        snowplow?.trackingResultEvent(
            action: "camera_pairing",
            status: "success",
            data: ["camera_serial": cameraSerial]
        )
    }
    static func pairingFailed(errorCode: String) {
        UniTrack.track("camera_pairing_failed", properties: [
            "error_code": errorCode,
        ])
        // Same family as pairingCompleted but the negative outcome side —
        // errorCode is what the funnel groups failures by.
        snowplow?.trackingResultEvent(
            action: "camera_pairing",
            status: "fail",
            errorCode: errorCode
        )
    }
    static func cameraRegistered(cameraSerial: String, cameraModel: String) {
        UniTrack.track("camera_registered", properties: [
            "camera_serial": cameraSerial, "camera_model": cameraModel,
        ])
    }

    // ── Performance metrics (#27, #28) ───────────────────────────────────────
    // #26 screen_load_completed is auto-captured by the SDK swizzler.
    static func streamFirstFrame(cameraSerial: String, ttffMs: Int,
                                 featureType: String = "live") {
        UniTrack.track("camera_stream_first_frame", properties: [
            "camera_serial": cameraSerial,
            "ttff_ms":       ttffMs,
            "feature_type":  featureType,
        ])
        // Snowplow leg: TTFF is a network-style timing — model it as an API
        // observation against the camera media endpoint. Backend can then
        // co-locate it with real HTTP latency samples in the same dashboard.
        snowplow?.trackingAPI(
            url:        "rtsp://camera/\(cameraSerial)/live",
            method:     "STREAM",
            status:     200,
            durationMs: ttffMs,
            data:       ["feature_type": featureType]
        )
    }
    static func streamBuffering(cameraSerial: String, action: String, bufferingDurationMs: Int) {
        UniTrack.track("camera_stream_buffering", properties: [
            "camera_serial":          cameraSerial,
            "action":                 action,    // "start" | "end"
            "buffering_duration_ms":  bufferingDurationMs,
        ])
    }

    // ── Interactions & errors (#29, #30) ─────────────────────────────────────
    static func cameraItemSelected(cameraSerial: String, sourceScreen: String) {
        UniTrack.track("camera_item_selected", properties: [
            "camera_serial": cameraSerial, "source_screen": sourceScreen,
        ])
        // Snowplow leg: this is the canonical "user tapped something"
        // payload — element_key is what funnels group by.
        snowplow?.trackingClickEvent(
            elementKey: "camera_item",
            label:      cameraSerial,
            screen:     sourceScreen,
            data:       ["camera_serial": cameraSerial]
        )
    }
    // #30 — real crashes are auto-captured by the SDK as `crash`; a portal
    // rule rewrites that to `event_crash`. Use this helper for non-fatal
    // exceptions the app wants to report explicitly under the same schema.
    static func applicationError(exceptionName: String, message: String,
                                 isFatal: Bool = false) {
        // Sheet event "application_error" — non-fatal exceptions the app
        // reports explicitly. Hard crashes (signal-trapped) flow through
        // the SDK's own `crash` event on next launch, not this helper.
        UniTrack.track("application_error", properties: [
            "exception_name": exceptionName,
            "message":        message,
            "is_fatal":       isFatal,
        ])
        // Snowplow leg via the convention crash helper — same iglu schema
        // the SDK's signal-handled crash takes after the portal rewrite,
        // so backend dashboards group fatal + non-fatal exceptions together.
        snowplow?.trackingCrash(
            message: message,
            fatal:   isFatal,
            type:    exceptionName
        )
    }


    static func identify(userId: String, plan: String) {
        UniTrack.identify(userId: userId, traits: ["plan": plan])
        // Keep Snowplow user_context entity in sync — every event after this
        // point carries the new user_id resolved from globals.
        snowplow?.setGlobalContext([
            "user":       ["user_id": userId, "plan": plan],
            "session_id": UUID().uuidString,
            "flavor":     "staging",
        ])
    }
}

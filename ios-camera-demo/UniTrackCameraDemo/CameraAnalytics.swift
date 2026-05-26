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

    /// Build UniTrack.Config + providers entirely from the fetched remote config.
    static func start(remote cfg: UniTrackRemoteConfig) {
        // Snowplow — only if the portal enabled it.
        if cfg.snowplow.enabled == true, let spEndpoint = cfg.snowplow.endpoint,
           let appId = cfg.snowplow.appId, !spEndpoint.isEmpty {
            let o = cfg.snowplow.options ?? [:]
            UniTrack.addProvider(SnowplowProvider(
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
                    exceptionAutotracking:       o["exceptionAutotracking"] ?? true,
                    installAutotracking:         o["installAutotracking"] ?? true
                )
            ))
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
        UniTrack.initialize(apiKey: apiKey, config: config)
    }

    // MARK: - Session (taxonomy #1, #2)
    // UniTrack keeps an implicit session_id but emits no session events, so we
    // emit them explicitly from app lifecycle.

    static func sessionStarted() {
        UniTrack.track("session_started", properties: ["source": "app_open"])
    }
    static func sessionEnded(reason: String) {
        UniTrack.track("session_ended", properties: ["reason": reason])
    }

    // MARK: - Navigation (#3, #4, #26) — fully auto-captured by the SDK now:
    // every UIViewController emits `screen_view` (class name) on viewDidAppear
    // and `screen_load_completed` (viewDidLoad→appear ms). No per-screen code,
    // no base class. (The old screenViewed/screenExited/screenLoadCompleted
    // helpers were removed — they duplicated what the swizzler does.)

    // MARK: - Camera live streaming B2C (#5, #6, #7)
    static func streamStarted(cameraId: String, quality: String) {
        UniTrack.track("camera_stream_started",
                       properties: ["camera_id": cameraId, "quality": quality])
    }
    static func streamEnded(cameraId: String, durationMs: Int) {
        UniTrack.track("camera_stream_ended",
                       properties: ["camera_id": cameraId, "duration_ms": durationMs])
    }
    static func streamPaused(cameraId: String) {
        UniTrack.track("camera_stream_paused", properties: ["camera_id": cameraId])
    }

    // MARK: - Camera events & playback B2C (#8, #9, #10)
    static func eventViewed(cameraId: String, eventType: String) {
        UniTrack.track("camera_event_viewed",
                       properties: ["camera_id": cameraId, "event_type": eventType])
    }
    static func playbackStarted(cameraId: String, recordingId: String) {
        UniTrack.track("camera_playback_started",
                       properties: ["camera_id": cameraId, "recording_id": recordingId])
    }
    static func playbackEnded(cameraId: String, durationMs: Int) {
        UniTrack.track("camera_playback_ended",
                       properties: ["camera_id": cameraId, "duration_ms": durationMs])
    }

    // MARK: - Notifications (#11, #12, #13, #14)
    // SDK only knows received/opened; the camera taxonomy needs four states, so
    // permission/sent/delivered are explicit, and clicked uses the SDK helper.
    static func notificationPermissionChecked(granted: Bool) {
        UniTrack.track("notification_permission_checked",
                       properties: ["granted": granted])
    }
    static func notificationSent(cameraId: String, type: String) {
        UniTrack.track("camera_notification_sent",
                       properties: ["camera_id": cameraId, "type": type])
    }
    static func notificationDelivered(cameraId: String, type: String) {
        UniTrack.track("camera_notification_delivered",
                       properties: ["camera_id": cameraId, "type": type])
    }
    static func notificationClicked(cameraId: String, type: String) {
        UniTrack.track("camera_notification_clicked",
                       properties: ["camera_id": cameraId, "type": type])
    }

    // MARK: - Camera settings B2C (#15)
    static func aiFeatureToggled(cameraId: String, feature: String, enabled: Bool) {
        UniTrack.track("camera_ai_feature_toggled",
                       properties: ["camera_id": cameraId, "feature": feature, "enabled": enabled])
    }

    // MARK: - VMS B2B (#16, #17, #18, #19)
    static func vmsCameraConnected(nvrId: String, channel: Int) {
        UniTrack.track("vms_camera_connected",
                       properties: ["nvr_id": nvrId, "channel": channel])
    }
    static func vmsCameraDisconnected(nvrId: String, channel: Int) {
        UniTrack.track("vms_camera_disconnected",
                       properties: ["nvr_id": nvrId, "channel": channel])
    }
    static func vmsRecordingPlayed(nvrId: String, channel: Int, recordingId: String) {
        UniTrack.track("vms_recording_played",
                       properties: ["nvr_id": nvrId, "channel": channel, "recording_id": recordingId])
    }
    static func vmsAlertViewed(nvrId: String, alertType: String) {
        UniTrack.track("vms_alert_viewed",
                       properties: ["nvr_id": nvrId, "alert_type": alertType])
    }

    // MARK: - Camera sharing B2C (#20, #21)
    static func cameraShared(cameraId: String, withUser: String) {
        UniTrack.track("camera_shared",
                       properties: ["camera_id": cameraId, "shared_with": withUser])
    }
    static func cameraShareRevoked(cameraId: String, fromUser: String) {
        UniTrack.track("camera_share_revoked",
                       properties: ["camera_id": cameraId, "revoked_from": fromUser])
    }

    // MARK: - Onboarding / pairing (#22, #23, #24, #25)
    static func pairingStarted(method: String) {
        UniTrack.track("camera_pairing_started", properties: ["method": method])
    }
    static func pairingCompleted(cameraId: String, durationMs: Int) {
        UniTrack.track("camera_pairing_completed",
                       properties: ["camera_id": cameraId, "duration_ms": durationMs])
    }
    static func pairingFailed(reason: String, code: String) {
        UniTrack.track("camera_pairing_failed",
                       properties: ["reason": reason, "error_code": code])
    }
    static func cameraRegistered(cameraId: String, model: String) {
        UniTrack.track("camera_registered",
                       properties: ["camera_id": cameraId, "model": model])
    }

    // MARK: - Performance metrics (#27, #28)
    // (#26 screen_load_completed is now auto-captured by the SDK swizzler.)
    static func streamFirstFrame(cameraId: String, ttfbMs: Int) {
        UniTrack.track("camera_stream_first_frame",
                       properties: ["camera_id": cameraId, "ttff_ms": ttfbMs])
    }
    static func streamBuffering(cameraId: String, durationMs: Int) {
        UniTrack.track("camera_stream_buffering",
                       properties: ["camera_id": cameraId, "duration_ms": durationMs])
    }

    // MARK: - Interactions & errors (#29, #30)
    static func cameraItemSelected(cameraId: String, position: Int) {
        UniTrack.track("camera_item_selected",
                       properties: ["camera_id": cameraId, "position": position])
    }
    // #30 application_error: real crashes are auto-captured as `crash`. This is
    // for handled/non-fatal errors the app wants to report.
    static func applicationError(domain: String, message: String, fatal: Bool = false) {
        UniTrack.track("application_error",
                       properties: ["domain": domain, "message": message, "fatal": fatal])
    }

    static func identify(userId: String, plan: String) {
        UniTrack.identify(userId: userId, traits: ["plan": plan])
    }
}

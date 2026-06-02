# unitrack-gen

CLI generator for the UniTrack iOS Snowplow provider's per-kind helpers.

Reads `snowplow.event_names` from the portal `/config` endpoint and emits one
typed `tracking<Kind>(data:)` helper per custom convention kind. App code then
calls `sp.trackingEvError(data: …)` with IDE autocomplete + type safety instead
of `sp.trackingCustomEvent("ev_error", data: …)` with a free-string name.

## Why a build-time generator?

Mobile SDKs are statically typed — Swift can't synthesize methods at runtime
from a dictionary. To get autocomplete + compile-time safety for custom kinds,
the helpers have to exist as concrete `func` declarations before the compiler
runs. This tool produces those declarations from the portal as the source of
truth, so the app code matches the operator's convention table exactly.

Trade-off: app rebuild required after the portal changes. The 5 built-in kinds
(`click`, `result`, `screen_view`, `crash`, `api`) ship with the SDK and don't
need regeneration — only custom kinds do.

## Usage

```bash
cd tools/unitrack-gen

swift run unitrack-gen \
  --api-key   utk_xxx                                              \
  --config-url https://mobix.asia/event-tracking-mobile/config     \
  --output    ../../ios-camera-demo/UniTrackCameraDemo/UniTrackSnowplowGenerated.swift
```

Commit the generated file. Re-run after every Convention table edit on the
portal.

## What it generates

For a portal config like:

```json
{
  "snowplow": {
    "iglu_vendor":     "vn.fpt.ftel.snowplow",
    "default_version": "1-0-0",
    "event_names": {
      "click":       "isc_event_click",
      "result":      "isc_event_result",
      "screen_view": "isc_event_screen_view",
      "crash":       "isc_event_crash",
      "api":         "isc_event_api",
      "ev_error":    "isc_ev_error",
      "ev_open":     "isc_ev_open"
    }
  }
}
```

…the generator emits:

```swift
// AUTO-GENERATED — DO NOT EDIT
public extension SnowplowProvider {
    /// Convention kind `ev_error` → schema `iglu:vn.fpt.ftel.snowplow/isc_ev_error/jsonschema/1-0-0`.
    func trackingEvError(data: [String: Any]? = nil, …) {
        trackSelfDescribing(schema: "iglu:vn.fpt.ftel.snowplow/isc_ev_error/jsonschema/1-0-0",
                            data: data ?? [:], …)
    }
    /// Convention kind `ev_open` → schema `iglu:vn.fpt.ftel.snowplow/isc_ev_open/jsonschema/1-0-0`.
    func trackingEvOpen(data: [String: Any]? = nil, …) {
        trackSelfDescribing(schema: "iglu:vn.fpt.ftel.snowplow/isc_ev_open/jsonschema/1-0-0",
                            data: data ?? [:], …)
    }
}
```

App side then uses:

```swift
sp.trackingEvError(data: ["message": "…", "code": "E_403"])
sp.trackingEvOpen(data:  ["url": "..."])
```

The 5 built-in kinds are skipped — they're shipped as typed helpers in the SDK
already.

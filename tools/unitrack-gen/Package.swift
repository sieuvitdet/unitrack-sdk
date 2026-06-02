// swift-tools-version:5.7
//
// unitrack-gen — fetch portal remote config, code-gen Swift helpers for every
// custom convention kind. Run with:
//
//   swift run unitrack-gen \
//     --api-key   utk_xxx \
//     --config-url https://mobix.asia/event-tracking-mobile/config \
//     --output    ../../ios-camera-demo/UniTrackCameraDemo/UniTrackSnowplowGenerated.swift
//
// Re-run after the portal Convention table changes; commit the generated file.

import PackageDescription

let package = Package(
    name: "unitrack-gen",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "unitrack-gen"),
    ]
)

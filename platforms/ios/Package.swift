// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "UniTrack",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
        .macOS(.v11)
    ],
    products: [
        // Core SDK — auto screen/tap/network/crash/OOM tracking + offline queue.
        .library(name: "UniTrack", targets: ["UniTrack"]),
        // Optional providers. Each pulls in its vendor SDK, so keep them as
        // separate products an app opts into.
        .library(name: "UniTrackFirebase", targets: ["UniTrackFirebase"]),
        .library(name: "UniTrackSnowplow", targets: ["UniTrackSnowplow"]),
    ],
    dependencies: [
        // Snowplow is fetched + linked by SPM — apps don't bring their own.
        .package(url: "https://github.com/snowplow/snowplow-ios-tracker.git", from: "6.0.0"),
        // NOTE: NO Firebase dependency declared here. Earlier versions pulled
        // firebase-ios-sdk directly, which collided with apps that already
        // ship Firebase via CocoaPods — Clang's module scanner fails with
        // "redefinition of module 'Firebase'" when the same module shows up
        // under two source trees.
        //
        // Instead, UniTrackFirebase imports FirebaseAnalytics via
        // `#if canImport(FirebaseAnalytics)` — the app is REQUIRED to provide
        // FirebaseAnalytics through one of:
        //   • CocoaPods: pod 'Firebase/Analytics', '10.27.0'
        //   • SPM:       add firebase-ios-sdk to the app target directly
        // Without either, FirebaseProvider compiles into a no-op shell that
        // logs "FirebaseAnalytics not available" and ignores tracking calls.
    ],
    targets: [
        // C/C++ core, vendored as real source files (copied from the monorepo's
        // core/ — not a symlink, so this package is self-contained when cloned
        // over SPM). SPM compiles the .cpp into the framework. Only include/
        // is exposed publicly (the ABI-stable C header).
        .target(
            name: "UniTrackCore",
            path: "Sources/UniTrackCore",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src")
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src")
            ],
            linkerSettings: [
                // The offline queue persists events to SQLite (system library).
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "UniTrack",
            dependencies: ["UniTrackCore"],
            path: "Sources/UniTrack"
        ),
        .target(
            name: "UniTrackFirebase",
            // Only depends on UniTrack. FirebaseAnalytics resolves via
            // canImport at compile time — provided by the consuming app's
            // own Firebase setup (Pods or SPM, whichever the app picked).
            dependencies: ["UniTrack"],
            path: "Sources/UniTrackFirebase"
        ),
        .target(
            name: "UniTrackSnowplow",
            dependencies: [
                "UniTrack",
                .product(name: "SnowplowTracker", package: "snowplow-ios-tracker"),
            ],
            path: "Sources/UniTrackSnowplow"
        ),
    ],
    cxxLanguageStandard: .cxx17
)

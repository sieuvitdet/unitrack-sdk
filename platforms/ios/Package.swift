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
        // Includes built-in FirebaseAdapter (reflection-based qua NSClassFromString
        // — app gọi `UniTrack.attachFirebaseAdapter()` khi đã tự link Firebase).
        // 0 import Firebase ở SDK, không cần product riêng.
        .library(name: "UniTrack", targets: ["UniTrack"]),
        // Snowplow forwarder — kéo vendor SnowplowTracker. App opt-in.
        .library(name: "UniTrackSnowplow", targets: ["UniTrackSnowplow"]),
    ],
    dependencies: [
        // Snowplow is fetched + linked by SPM — apps don't bring their own.
        .package(url: "https://github.com/snowplow/snowplow-ios-tracker.git", from: "6.0.0"),
    ],
    targets: [
        // C/C++ core, vendored as REAL committed source files (no symlinks —
        // SPM rejects symlinks that escape the package root, and CocoaPods'
        // lint sandbox can't see the monorepo's top-level core/ either). The
        // copy under Sources/UniTrackCore/{src,include/unitrack} mirrors the
        // monorepo's core/ layout 1:1; refresh it via platforms/ios/sync_core.sh
        // whenever the C core changes. SPM compiles the .cpp into the
        // framework. Only include/unitrack/unitrack.h is exposed publicly
        // (the ABI-stable C header that every binding consumes).
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
            name: "UniTrackSnowplow",
            dependencies: [
                "UniTrack",
                .product(name: "SnowplowTracker", package: "snowplow-ios-tracker"),
            ],
            path: "Providers/UniTrackSnowplow/Sources"
        ),
    ],
    cxxLanguageStandard: .cxx17
)

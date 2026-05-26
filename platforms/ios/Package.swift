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
        .library(name: "UniTrack", targets: ["UniTrack"]),
    ],
    targets: [
        // C/C++ core, vendored as source. SPM compiles the .cpp and bundles
        // libunitrack into the framework.
        .target(
            name: "UniTrackCore",
            path: "Sources/UniTrackCore",
            // The C++ implementation (src/, symlinked to the repo core/src) is
            // compiled here; only include/ is exposed publicly (the C header).
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
                // The offline queue persists events to SQLite.
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "UniTrack",
            dependencies: ["UniTrackCore"],
            path: "Sources/UniTrack"
        ),
        // Note: the test target was removed — Tests/UniTrackTests does not
        // exist in this checkout and its presence broke SPM resolution.
    ],
    cxxLanguageStandard: .cxx17
)

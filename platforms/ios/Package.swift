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
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .target(
            name: "UniTrack",
            dependencies: ["UniTrackCore"],
            path: "Sources/UniTrack"
        ),
        .testTarget(
            name: "UniTrackTests",
            dependencies: ["UniTrack"],
            path: "Tests/UniTrackTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)

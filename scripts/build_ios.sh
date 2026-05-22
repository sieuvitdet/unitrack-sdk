#!/usr/bin/env bash
# Builds UniTrack.xcframework for iOS device + simulator + Mac Catalyst.
#
# Usage: ./scripts/build_ios.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/platforms/ios"

BUILD="$ROOT/build/ios"
rm -rf "$BUILD"
mkdir -p "$BUILD"

archive() {
    local dest=$1; local sdk=$2; local destFlag=$3
    xcodebuild archive \
        -scheme UniTrack \
        -destination "$destFlag" \
        -archivePath "$dest" \
        -derivedDataPath "$BUILD/derived" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES
}

archive "$BUILD/ios-device.xcarchive"    iphoneos       "generic/platform=iOS"
archive "$BUILD/ios-sim.xcarchive"       iphonesimulator "generic/platform=iOS Simulator"

xcodebuild -create-xcframework \
    -framework "$BUILD/ios-device.xcarchive/Products/Library/Frameworks/UniTrack.framework" \
    -framework "$BUILD/ios-sim.xcarchive/Products/Library/Frameworks/UniTrack.framework" \
    -output "$ROOT/dist/UniTrack.xcframework"

echo "[build_ios] wrote $ROOT/dist/UniTrack.xcframework"

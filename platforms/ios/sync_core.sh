#!/usr/bin/env bash
# Copies the shared C++ core into CoreVendor/ as REAL files (not symlinks).
#
# CocoaPods builds the Pods.xcodeproj from physical files inside the pod
# directory; it does not follow symlinks that point outside the pod root (the
# Sources/UniTrackCore/src symlink works for SPM but not for CocoaPods). So for
# the CocoaPods integration we copy core/ in here. Run this before `pod install`
# whenever the C core changes. CoreVendor/ is git-ignored (regenerate it).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"   # platforms/ios
CORE="$HERE/../../core"

rm -rf "$HERE/CoreVendor"
mkdir -p "$HERE/CoreVendor"
cp -RL "$CORE/src"     "$HERE/CoreVendor/src"
cp -RL "$CORE/include" "$HERE/CoreVendor/include"
echo "[sync_core] copied C++ core into $HERE/CoreVendor"

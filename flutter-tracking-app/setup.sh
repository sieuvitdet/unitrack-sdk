#!/usr/bin/env bash
# One-time setup for the Mobix UniTrack Flutter demo.
#
# This repo ships the Dart source (lib/) and pubspec.yaml only. The large,
# generated platform folders (ios/, android/, etc.) are produced by Flutter
# itself. Run this once on a machine that has the Flutter SDK installed.
#
#   ./setup.sh
#   flutter run            # pick an iOS simulator / Android device
#
# Prereqs: Flutter SDK on PATH (`flutter --version`), and for iOS: Xcode + CocoaPods.

set -euo pipefail
cd "$(dirname "$0")"

# The unitrack Flutter plugin's iOS pod needs the native SDK + C++ core copied
# into its Native/ dir (CocoaPods can't reach source outside the pod dir).
echo "==> syncing native iOS SDK into the plugin pod"
bash ../platforms/flutter/ios/sync_native.sh

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK not found on PATH."
  echo "Install: https://docs.flutter.dev/get-started/install"
  echo "Quick (git): git clone https://github.com/flutter/flutter.git -b stable ~/flutter"
  echo "             export PATH=\"\$PATH:\$HOME/flutter/bin\""
  exit 1
fi

echo "==> flutter version"
flutter --version

# Generate the native platform scaffolding in-place without clobbering lib/.
# --project-name must match pubspec (mobix_tracking_demo).
echo "==> generating platform folders (ios/android)"
flutter create --project-name mobix_tracking_demo --platforms=ios,android .

echo "==> flutter pub get"
flutter pub get

# iOS: the unitrack Flutter plugin pod is self-contained — it vendors the native
# Swift SDK + C++ core directly (no separate, unpublished 'UniTrack' pod). We
# only need static linkage so the bundled C++ core links correctly.
if [[ "$OSTYPE" == darwin* ]] && [[ -d ios ]]; then
  PODFILE="ios/Podfile"
  if grep -q '^[[:space:]]*use_frameworks!$' "$PODFILE"; then
    echo "==> setting static linkage in ios/Podfile (required for the C++ core)"
    /usr/bin/sed -i '' 's/^\([[:space:]]*\)use_frameworks!$/\1use_frameworks! :linkage => :static/' "$PODFILE" 2>/dev/null || true
  fi
  echo "==> pod install (iOS)"
  (cd ios && pod install || echo "pod install failed — see README 'iOS native SDK' section")
fi

cat <<'EOF'

Setup complete.

Run it:
  flutter devices            # see available simulators/devices
  flutter run                # launches on the selected device

Events flow to: https://mobix.asia/event-tracking-mobile
Watch them live at the same URL in a browser.
EOF

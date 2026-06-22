Pod::Spec.new do |s|
  s.name             = 'unitrack'
  # No separate 'UniTrack' pod exists (this pod vendors the native Swift SDK +
  # C++ core directly), so the module name stays 'unitrack' — which is what
  # Flutter's GeneratedPluginRegistrant imports.
  s.version          = '1.1.3'
  s.summary          = 'UniTrack — universal mobile analytics SDK for Flutter.'
  s.description      = 'Auto-capture screens, taps, network, crashes, OOM, JSON errors.'
  s.homepage         = 'https://github.com/sieuvitdet/unitrack-sdk'
  s.license          = { :type => 'MIT' }
  s.author           = 'UniTrack'
  s.source           = { :path => '.' }

  # CocoaPods only includes source files that physically live within the pod
  # directory (it won't glob through `..` or symlinks). The native iOS Swift SDK
  # and the C++ core are therefore copied into Native/ by setup.sh (script:
  # sync_native.sh). The C public header (Classes/include/unitrack.h) is a local
  # copy so it lands in the generated umbrella, exposing the C `ut_*` API to Swift.
  s.source_files = [
    'Classes/**/*',                    # Flutter Swift bridge + C public header
    'Native/swift/**/*.swift',         # native iOS Swift SDK
    'Native/core/src/**/*.{cpp,h}',    # C++ core implementation
    'Native/core/include/unitrack/*.h' # C++ core public headers
  ]
  s.public_header_files = 'Classes/include/unitrack.h'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  s.libraries = 'sqlite3', 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/Native/core/include $(PODS_TARGET_SRCROOT)/Native/core/src $(PODS_TARGET_SRCROOT)/Classes/include'
  }
end

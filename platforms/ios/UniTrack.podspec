Pod::Spec.new do |s|
  s.name             = 'UniTrack'
  s.version          = '1.0.0'
  s.summary          = 'Universal Mobile Analytics SDK — auto-capture screens, taps, network, crashes, OOM, JSON errors.'
  s.description      = <<-DESC
    UniTrack is a zero-config analytics SDK. One init call gives you:
    automatic screen tracking, tap tracking by view identifier,
    URLSession network tracking, memory warning reports, JSON parse
    error reports, crash reports, and offline event queueing.
  DESC
  s.homepage         = 'https://github.com/unitrack/sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'UniTrack' => 'sdk@unitrack.io' }
  s.source           = { :git => 'https://github.com/unitrack/sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions = ['5.7']

  # The C++ core is vendored into CoreVendor/ as REAL files by sync_core.sh
  # (CocoaPods won't follow the SPM symlink out of the pod root). All paths stay
  # inside this podspec's dir so they work with `:path => '../platforms/ios'`.
  # Run platforms/ios/sync_core.sh before `pod install`.
  s.prepare_command = 'bash sync_core.sh'
  s.source_files = [
    'Sources/UniTrack/**/*.swift',
    'Sources/UniTrackCore/include/unitrack.h',
    'CoreVendor/src/**/*.{cpp,h}',
    'CoreVendor/include/unitrack/*.h'
  ]
  s.public_header_files = 'Sources/UniTrackCore/include/unitrack.h'

  s.libraries = 'sqlite3', 'c++'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/CoreVendor/include" "$(PODS_TARGET_SRCROOT)/CoreVendor/src"'
  }
end

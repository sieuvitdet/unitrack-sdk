require 'json'
pkg = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'RNUniTrack'
  s.version      = pkg['version']
  s.summary      = pkg['description']
  s.license      = pkg['license']
  s.author       = 'UniTrack'
  s.homepage     = 'https://github.com/sieuvitdet/unitrack-sdk'
  s.source       = { :git => 'https://github.com/sieuvitdet/unitrack-sdk.git', :tag => "v#{s.version}" }
  s.platform     = :ios, '13.0'
  s.swift_version = '5.0'

  # Bridge sources + vendored native SDK + C++ core. Same pattern the Flutter
  # plugin uses — Native/ is populated by ios/sync_native.sh from this repo's
  # platforms/ios/ and core/ trees before publishing the npm package.
  s.source_files = [
    'ios/RNUniTrack.{m,swift}',
    'ios/include/*.h',                  # C public header (umbrella exposes it)
    'ios/Native/swift/**/*.swift',      # UniTrack Swift SDK
    'ios/Native/core/src/**/*.{cpp,h}', # C++ core implementation
    'ios/Native/core/include/unitrack/*.h' # C++ core public headers
  ]
  s.public_header_files = 'ios/include/unitrack.h'

  s.dependency 'React-Core'

  s.libraries = 'sqlite3', 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' =>
      '$(PODS_TARGET_SRCROOT)/ios/Native/core/include ' +
      '$(PODS_TARGET_SRCROOT)/ios/Native/core/src ' +
      '$(PODS_TARGET_SRCROOT)/ios/include'
  }
end

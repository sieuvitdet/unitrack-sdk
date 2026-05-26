Pod::Spec.new do |s|
  s.name             = 'UniTrackFirebase'
  s.version          = '1.0.0'
  s.summary          = 'Firebase Analytics provider for UniTrack.'
  s.homepage         = 'https://github.com/unitrack/sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'UniTrack' => 'sdk@unitrack.io' }
  s.source           = { :git => 'https://github.com/unitrack/sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions = ['5.7']

  s.source_files = 'Sources/**/*.swift'

  # Core SDK (the AnalyticsProvider protocol) + Firebase Analytics.
  # The app must add GoogleService-Info.plist to the Runner target.
  s.dependency 'UniTrack'
  s.dependency 'Firebase/Analytics'
  s.static_framework = true
end

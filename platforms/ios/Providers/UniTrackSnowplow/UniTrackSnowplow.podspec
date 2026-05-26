Pod::Spec.new do |s|
  s.name             = 'UniTrackSnowplow'
  s.version          = '1.0.0'
  s.summary          = 'Snowplow provider for UniTrack — forwards events to a Snowplow collector.'
  s.homepage         = 'https://github.com/unitrack/sdk'
  s.license          = { :type => 'MIT' }
  s.author           = { 'UniTrack' => 'sdk@unitrack.io' }
  s.source           = { :git => 'https://github.com/unitrack/sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions = ['5.7']

  s.source_files = 'Sources/**/*.swift'

  # Core SDK (the AnalyticsProvider protocol) + the real Snowplow tracker.
  s.dependency 'UniTrack'
  s.dependency 'SnowplowTracker', '~> 6.0'
end

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

  # UniTrack core (the AnalyticsProvider protocol).
  #
  # IMPORTANT: this pod is NOT published to CocoaPods Trunk — both UniTrack
  # and UniTrackSnowplow live side-by-side in this monorepo. Consume them
  # through your app's Podfile via :path dependencies, e.g.:
  #
  #   pod 'UniTrack',          :path => '../sdk/platforms/ios'
  #   pod 'UniTrackSnowplow',  :path => '../sdk/platforms/ios/Providers/UniTrackSnowplow'
  #
  # The version pin below MUST match the UniTrack.podspec at the repo root so
  # `pod install` rejects a mismatched local checkout (e.g. UniTrack bumped to
  # 1.1.x while this provider still ships 1.0.x). When bumping, update BOTH
  # podspecs' s.version in lockstep + this `~>` constraint.
  s.dependency 'UniTrack', '~> 1.0'
  s.dependency 'SnowplowTracker', '~> 6.0'
end

Pod::Spec.new do |s|
  s.name             = 'unitrack'
  s.version          = '1.0.0'
  s.summary          = 'UniTrack — universal mobile analytics SDK for Flutter.'
  s.description      = 'Auto-capture screens, taps, network, crashes, OOM, JSON errors.'
  s.homepage         = 'https://github.com/unitrack/sdk'
  s.license          = { :type => 'MIT' }
  s.author           = 'UniTrack'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency       'Flutter'
  s.dependency       'UniTrack', '~> 1.0'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

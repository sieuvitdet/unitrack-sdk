require 'json'
pkg = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'RNUniTrack'
  s.version      = pkg['version']
  s.summary      = pkg['description']
  s.license      = pkg['license']
  s.author       = 'UniTrack'
  s.homepage     = 'https://github.com/unitrack/sdk'
  s.source       = { :git => 'https://github.com/unitrack/sdk.git', :tag => "v#{s.version}" }
  s.platform     = :ios, '13.0'
  s.source_files = 'ios/**/*.{h,m,mm}'
  s.dependency   'React-Core'
  s.dependency   'UniTrack', '~> 1.0'
end

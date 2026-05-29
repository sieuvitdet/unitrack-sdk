#!/usr/bin/env ruby
# Generates UniTrackCameraDemo.xcodeproj (a plain UIKit app) that consumes the
# UniTrack SDK as a REMOTE SWIFT PACKAGE from GitHub (no CocoaPods).
#
#   gem install xcodeproj        # one-time
#   ruby gen_project.rb          # simulator
#   DEV_TEAM=XXXX ruby gen_project.rb   # real device
#   open UniTrackCameraDemo.xcodeproj   # Xcode resolves the package on open
#
# Xcode fetches https://github.com/sieuvitdet/unitrack-ios-package (branch main),
# which exposes the products UniTrack / UniTrackFirebase / UniTrackSnowplow and
# pulls in Firebase + Snowplow transitively.

require 'xcodeproj'
require 'fileutils'

here      = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(here, 'UniTrackCameraDemo.xcodeproj')
app_name  = 'UniTrackCameraDemo'
src_dir   = File.join(here, app_name)

PKG_URL      = 'https://github.com/sieuvitdet/unitrack-ios-package'
PKG_PRODUCTS = %w[UniTrack UniTrackFirebase UniTrackSnowplow]

FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)
target  = project.new_target(:application, app_name, :ios, '15.0')

# Add Swift sources + Info.plist.
group = project.main_group.new_group(app_name, app_name)
Dir.glob(File.join(src_dir, '*.swift')).sort.each do |f|
  target.add_file_references([group.new_reference(f)])
end
group.new_reference(File.join(src_dir, 'Info.plist'))

# GoogleService-Info.plist (Firebase) — bundle as a RESOURCE (runtime read).
gsi = File.join(src_dir, 'GoogleService-Info.plist')
if File.exist?(gsi)
  target.add_resources([group.new_reference(gsi)])
  puts "Bundling Firebase config: #{gsi}"
end

# --- Remote Swift Package dependency (the git repo, branch main) -------------
pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg.repositoryURL = PKG_URL
# Track the `main` branch (use :version/:tag instead once the repo is tagged).
pkg.requirement = { 'kind' => 'branch', 'branch' => 'main' }
project.root_object.package_references << pkg

PKG_PRODUCTS.each do |product|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = product
  target.package_product_dependencies << dep
end

# To run on a REAL DEVICE we sign with this Apple Development team. Override with
# DEV_TEAM=<id>, or DEV_TEAM= (empty) to disable signing (simulator only).
dev_team = ENV.fetch('DEV_TEAM', '7755R4CX4U')

target.build_configurations.each do |c|
  c.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'  => 'asia.mobix.unitrackcamerademo',
    'INFOPLIST_FILE'             => "#{app_name}/Info.plist",
    'IPHONEOS_DEPLOYMENT_TARGET' => '15.0',
    'SWIFT_VERSION'              => '5.0',
    'TARGETED_DEVICE_FAMILY'     => '1,2',
    'GENERATE_INFOPLIST_FILE'    => 'NO',
    # The package vendors a C++ core + links sqlite.
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY'           => 'libc++',
    'OTHER_LDFLAGS'               => ['$(inherited)', '-lc++', '-lsqlite3']
  )

  if dev_team && !dev_team.empty?
    c.build_settings['CODE_SIGN_STYLE']       = 'Automatic'
    c.build_settings['DEVELOPMENT_TEAM']      = dev_team
    c.build_settings['CODE_SIGN_IDENTITY']    = 'Apple Development'
    c.build_settings['CODE_SIGNING_ALLOWED']  = 'YES'
    c.build_settings['CODE_SIGNING_REQUIRED'] = 'YES'
  else
    c.build_settings['CODE_SIGNING_ALLOWED']  = 'NO'
  end
end

project.save
puts "Generated #{proj_path}"
puts "Swift Package: #{PKG_URL} (branch main) → #{PKG_PRODUCTS.join(', ')}"
if dev_team && !dev_team.empty?
  puts "Signing: automatic, team #{dev_team} (device + simulator)."
else
  puts "Signing: OFF — simulator only. (DEV_TEAM=<id> for a device.)"
end
puts "Next: open #{app_name}.xcodeproj  (Xcode resolves the package automatically)"

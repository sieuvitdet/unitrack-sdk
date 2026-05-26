#!/usr/bin/env ruby
# Generates UniTrackUIKitDemo.xcodeproj with a local Swift Package dependency
# on the UniTrack SDK (../platforms/ios). Run: ruby gen_project.rb

require 'xcodeproj'

here       = File.dirname(File.expand_path(__FILE__))
proj_path  = File.join(here, 'UniTrackUIKitDemo.xcodeproj')
app_name   = 'UniTrackUIKitDemo'
src_dir    = File.join(here, app_name)

File.delete(proj_path) rescue nil
Dir.glob(proj_path).each { |p| FileUtils.rm_rf(p) } if Dir.exist?(proj_path)
require 'fileutils'
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

target = project.new_target(:application, app_name, :ios, '15.0')

# Add Swift sources + Info.plist group.
group = project.main_group.new_group(app_name, app_name)
Dir.glob(File.join(src_dir, '*.swift')).sort.each do |f|
  ref = group.new_reference(f)
  target.add_file_references([ref])
end
group.new_reference(File.join(src_dir, 'Info.plist'))

# Local Swift Package: UniTrack at ../platforms/ios
pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
pkg.relative_path = '../platforms/ios'
project.root_object.package_references << pkg

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.product_name = 'UniTrack'
dep.package = pkg
target.package_product_dependencies << dep

# Build settings for both configs.
target.build_configurations.each do |c|
  c.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'        => 'asia.mobix.unitrackuikitdemo',
    'INFOPLIST_FILE'                   => "#{app_name}/Info.plist",
    'IPHONEOS_DEPLOYMENT_TARGET'       => '15.0',
    'SWIFT_VERSION'                    => '5.0',
    'TARGETED_DEVICE_FAMILY'           => '1,2',
    'GENERATE_INFOPLIST_FILE'          => 'NO',
    'CODE_SIGNING_ALLOWED'             => 'NO',     # simulator runs unsigned
    'CLANG_CXX_LANGUAGE_STANDARD'      => 'c++17',
    'CLANG_CXX_LIBRARY'                => 'libc++',
    'ENABLE_USER_SCRIPT_SANDBOXING'    => 'NO'
  )
end

# Link libc++ / sqlite3 used by the C++ core.
project.frameworks_group
phase = target.frameworks_build_phase

project.save

# Create a shared scheme so `xcodebuild -scheme` and Xcode's Run work.
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(proj_path, app_name, true)

puts "Generated #{proj_path}"
puts "Open with: open #{proj_path}   (or build with xcodebuild)"

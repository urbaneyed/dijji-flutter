#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'dijji'
  s.version          = '1.1.0-alpha'
  s.summary          = 'Dijji analytics, engagement, and in-app messaging SDK for Flutter.'
  s.description      = <<-DESC
Dijji Flutter plugin: native crash capture (NSException + POSIX signals),
analytics ingestion, and in-app messaging. Pure-Swift implementation, no
third-party dependencies.
                       DESC
  s.homepage         = 'https://dijji.com'
  s.license          = { :type => 'Apache 2.0', :file => '../LICENSE' }
  s.author           = { 'Dijji' => 'rishi@kaam.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end

Pod::Spec.new do |s|
  s.name             = 'ConvertSDK'
  s.version          = '1.0.0'
  s.summary          = 'Convert Experiences iOS SDK — A/B testing, feature flags, conversion tracking.'
  s.description      = 'Swift SDK for Convert Experiences: A/B testing, feature flags, segmentation and conversion tracking on iOS, iPadOS, tvOS and macOS.'
  s.homepage         = 'https://github.com/convertcom/ios-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Convert.com' => 'support@convert.com' }
  s.source           = { :git => 'https://github.com/convertcom/ios-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.tvos.deployment_target = '15.0'
  s.swift_versions   = ['6.0']
  s.source_files     = 'Sources/ConvertSDK/**/*.swift'
  s.dependency 'ConvertSDKCore', '1.0.0'
  s.resource_bundles = {
    'ConvertSDKPrivacy' => ['Sources/ConvertSDK/Resources/PrivacyInfo.xcprivacy']
  }
end

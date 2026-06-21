Pod::Spec.new do |s|
  s.name             = 'ConvertSwiftSDK'
  s.version          = '1.0.0'
  s.summary          = 'Convert Experiences iOS SDK — A/B testing, feature flags, conversion tracking.'
  s.description      = 'Swift SDK for Convert Experiences: A/B testing, feature flags, segmentation and conversion tracking on iOS, iPadOS, tvOS and macOS.'
  s.homepage         = 'https://github.com/convertcom/ios-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Convert.com' => 'support@convert.com' }
  s.source           = { :git => 'https://github.com/convertcom/ios-sdk.git', :tag => "v#{s.version}" }
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.tvos.deployment_target = '15.0'
  s.swift_versions   = ['6.0']
  s.source_files     = 'Sources/ConvertSwiftSDK/**/*.swift'
  s.dependency 'ConvertSwiftSDKCore', s.version.to_s
  # Must match ConvertSwiftSDKCore's -package-name so this module can access Core's
  # `package`-level symbols (SPM does this implicitly via the shared package).
  s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '-package-name ConvertSwiftSDK' }
  s.resource_bundles = {
    'ConvertSwiftSDKPrivacy' => ['Sources/ConvertSwiftSDK/Resources/PrivacyInfo.xcprivacy']
  }
end

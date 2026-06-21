Pod::Spec.new do |s|
  s.name             = 'ConvertSwiftSDKCore'
  s.version          = '1.0.0'
  s.summary          = 'Convert Experiences iOS SDK core engine (bucketing, rules, config).'
  s.description      = 'Core engine for the Convert Experiences iOS SDK: bucketing, rules, config decoding and segmentation.'
  s.homepage         = 'https://github.com/convertcom/ios-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Convert.com' => 'support@convert.com' }
  s.source           = { :git => 'https://github.com/convertcom/ios-sdk.git', :tag => "v#{s.version}" }
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.tvos.deployment_target = '15.0'
  s.swift_versions   = ['6.0']
  s.source_files     = 'Sources/ConvertSwiftSDKCore/**/*.swift'
  # SPM passes -package-name implicitly so the two targets can share `package`-level
  # symbols; CocoaPods builds each pod as a separate module without it. Inject the same
  # package name on BOTH pods so `package` declarations compile and resolve across them.
  s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '-package-name ConvertSwiftSDK' }
end

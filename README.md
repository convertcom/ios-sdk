# Convert iOS SDK

A/B testing, feature flags, segmentation, and conversion tracking for iOS, iPadOS, tvOS, and macOS.

```swift
import ConvertSDK

let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
try await sdk.ready()                                   // gates decisioning

let context = sdk.createContext()                       // visitorId optional → persistent auto-UUID
if let variation = await context.runExperience("pricing-test") {
    print(variation.key)                                // switch your UI on the key, e.g. "variant-a"
}
await context.trackConversion("purchase-goal", goalData: [.amount: .double(49.99)])
```

## Install

### Swift Package Manager (primary)

In Xcode, choose **File ▸ Add Package Dependencies…**, enter the package URL, and add the `ConvertSDK` product to your target.

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/convertcom/ios-sdk.git", from: "1.0.0")
]
```

Then list `ConvertSDK` in your target's dependencies.

### CocoaPods

Add the pod to your `Podfile`:

```ruby
pod 'ConvertSDK', '~> 1.0'
```

Then run `pod install`. `ConvertSDK` pulls `ConvertSDKCore` transitively — you only name `ConvertSDK`.

### Platforms

iOS 15+, macOS 12+, tvOS 15+. iPadOS rides the iOS target.

## The one ordering rule

`ready()` gates decisioning. Everything else is order-independent.

Call `ready()` once after construction and await it before deciding. `runExperience` / `runFeature` called before `ready()` resolves return a degraded result — `nil` from `runExperience`, a disabled `Feature` from `runFeature` — never a crash. Once `ready()` returns, the cached config drives every subsequent decision with no further network.

A `nil` variation also covers the visitor being ineligible or the experience key being unknown. None of these are errors. `ready()` is the only call that throws, and only on an unrecoverable configuration error such as an empty SDK key.

## Documentation

- **<doc:GettingStarted>** — the linear install → init → ready → context → decide → track path.
- **<doc:OfflineAndBackgroundDelivery>** — how decisions and queued bucketing events behave offline and after the app is suspended.
- **<doc:FailureDetection>** — detecting a failed or slow start.
- **<doc:Privacy>** — the privacy manifest and visitor-identity guidance.

The full guide and the symbol-level API reference are the DocC articles in `Sources/ConvertSDK/ConvertSDK.docc/`.

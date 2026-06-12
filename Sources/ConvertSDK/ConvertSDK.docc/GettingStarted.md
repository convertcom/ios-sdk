# Getting Started

Add the SDK, initialize it, await readiness, create a context, run an experience, and track a conversion.

## Overview

This walks the linear path a first integration follows: install → init → ready → context → decide → track. A developer who completes these steps can ship.

### Install

Swift Package Manager — add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/convertcom/ios-sdk.git", from: "1.0.0")
```

Then add `ConvertSDK` to your target's dependencies. In Xcode, use **File ▸ Add Package Dependencies…** and enter the same URL.

CocoaPods — add the pod to your `Podfile`:

```ruby
pod 'ConvertSDK', '~> 1.0'
```

Then run `pod install` and open the generated `.xcworkspace`.

### Initialize

Construct the SDK with a ``ConvertConfiguration``. The initializer never blocks — configuration loads asynchronously:

```swift
import ConvertSDK

let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
```

Only ``ConvertConfiguration/init(sdkKey:sdkKeySecret:environment:apiConfigEndpoint:apiTrackEndpoint:bucketingMaxTraffic:bucketingHashSeed:dataRefreshIntervalMs:eventsBatchSize:eventsReleaseIntervalMs:ruleKeysCaseSensitive:ruleNegation:logLevel:networkTracking:networkCacheLevel:)`` requires `sdkKey`; every other field carries a JavaScript-SDK-parity default.

### Await readiness

``ConvertSDK/ready()`` suspends until the first configuration is available — from a live fetch or a cache, including a cold start while offline:

```swift
try await sdk.ready()
```

It throws only on an unrecoverable configuration error (an empty SDK key, or empty/invalid direct-data). A transient network failure does not throw — the SDK resolves degraded and serves a cached config if one exists. To detect a failed or slow start, see <doc:FailureDetection>.

### Create a context

A context carries the visitor identity. Pass a `visitorId`, or omit it for a persistent auto-generated UUID (never the IDFA or IDFV):

```swift
let context = sdk.createContext()
```

### Run an experience

``ConvertContext/runExperience(_:enableTracking:)`` buckets the visitor and returns the assigned ``Variation``. Switch your UI on the variation `key`:

```swift
if let variation = await context.runExperience("pricing-test") {
    print("Variation \(variation.key)")     // e.g. "variant-a"
} else {
    // nil = a degraded result: ineligible, unknown experience, or not yet ready — not an error
}
```

### Track a conversion

``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)`` enqueues a conversion event for a goal `key`. Conversions dedup per visitor + goal; an optional ``GoalData`` map carries metrics such as a revenue amount:

```swift
await context.trackConversion("purchase-goal", goalData: [.amount: .double(49.99)])
```

An unknown goal logs a `[WARN]` line ("Goal not found…") and is dropped — it is never a thrown error.

### Next steps

Learn how decisions and events behave offline in <doc:OfflineAndBackgroundDelivery>, how to detect a failed start in <doc:FailureDetection>, and where the privacy guidance lives in <doc:Privacy>.

# Getting Started

Add the SDK, initialize it, await readiness, create a context, run an experience, and track a conversion.

## Overview

This walks the linear path a first integration follows: install → init → ready → context → decide → track. A developer who completes these steps can ship.

### Install

Swift Package Manager — add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/convertcom/ios-sdk.git", from: "1.0.0")
```

Then add `ConvertSwiftSDK` to your target's dependencies. In Xcode, use **File ▸ Add Package Dependencies…** and enter the same URL.

CocoaPods — add the pod to your `Podfile`:

```ruby
pod 'ConvertSwiftSDK', '~> 1.0'
```

Then run `pod install` and open the generated `.xcworkspace`.

### Initialize

Construct the SDK with a ``ConvertConfiguration``. The initializer never blocks — configuration loads asynchronously:

```swift
import ConvertSwiftSDK

let sdk = ConvertSwiftSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
```

Only ``ConvertConfiguration/init(sdkKey:sdkKeySecret:environment:apiConfigEndpoint:apiTrackEndpoint:bucketingMaxTraffic:bucketingHashSeed:dataRefreshIntervalMs:eventsBatchSize:eventsReleaseIntervalMs:ruleKeysCaseSensitive:ruleNegation:logLevel:networkTracking:networkCacheLevel:)`` requires `sdkKey`; every other field carries a JavaScript-SDK-parity default.

### Configure

``ConvertConfiguration`` is an immutable value: you set its fields once at construction and they never change. The fields are flat Swift properties — there is no nested `network` object. Below they are grouped by concern for readability (the grouping mirrors the JavaScript SDK's config object), but the Swift identifiers you pass are the flat names in the **Property** column.

**Identity and endpoints**

| Property | Type | Default | Meaning |
|---|---|---|---|
| ``ConvertConfiguration/sdkKey`` | `String` | *(required)* | Project SDK key identifying the Convert project to load. |
| ``ConvertConfiguration/sdkKeySecret`` | `String?` | `nil` | SDK key secret for authenticated endpoints; `nil` when unused. |
| ``ConvertConfiguration/environment`` | `String?` | `nil` | Named environment selector; `nil` selects the default. |
| ``ConvertConfiguration/apiConfigEndpoint`` | `String` | `"https://cdn-4.convertexperiments.com/api/v1"` | Base URL for fetching project configuration (no trailing slash). |
| ``ConvertConfiguration/apiTrackEndpoint`` | `String` | `"https://cdn-4.convertexperiments.com/api/v1"` | Base URL for delivering tracking events (no trailing slash). |

**Bucketing**

| Property | Type | Default | Meaning |
|---|---|---|---|
| ``ConvertConfiguration/bucketingMaxTraffic`` | `Int` | `10000` | Inclusive upper bound of the bucketing traffic range. |
| ``ConvertConfiguration/bucketingHashSeed`` | `UInt32` | `9999` | MurmurHash3 seed used when hashing the bucketing key. |

**Refresh and event delivery**

| Property | Type | Default | Meaning |
|---|---|---|---|
| ``ConvertConfiguration/dataRefreshIntervalMs`` | `Int` | `300000` | Milliseconds between remote configuration refreshes. |
| ``ConvertConfiguration/eventsBatchSize`` | `Int` | `10` | Number of queued events flushed per release batch. |
| ``ConvertConfiguration/eventsReleaseIntervalMs`` | `Int` | `1000` | Milliseconds between event-queue release attempts. |

**Rule matching**

| Property | Type | Default | Meaning |
|---|---|---|---|
| ``ConvertConfiguration/ruleKeysCaseSensitive`` | `Bool` | `true` | Whether rule key comparisons are case-sensitive. |
| ``ConvertConfiguration/ruleNegation`` | `Bool` | `false` | Whether rule matching applies negation semantics. |

**Logging, tracking, and caching**

| Property | Type | Default | Meaning |
|---|---|---|---|
| ``ConvertConfiguration/logLevel`` | ``LogLevel`` | `.warn` | Log severity threshold; messages below this level are suppressed. |
| ``ConvertConfiguration/networkTracking`` | `Bool` | `true` | Whether event/network delivery is enabled. Set `false` to suppress all tracking while bucketing continues — see <doc:OfflineAndBackgroundDelivery>. |
| ``ConvertConfiguration/networkCacheLevel`` | ``CacheLevel`` | `.normal` | CDN cache level applied to config fetches (``CacheLevel/normal`` or ``CacheLevel/low``). |

``LogLevel`` ranges from most verbose to fully muted: ``LogLevel/trace`` < ``LogLevel/debug`` < ``LogLevel/info`` < ``LogLevel/warn`` < ``LogLevel/error`` < ``LogLevel/silent``.

> Note: The JavaScript SDK's `network.source` field is **not exposed** on iOS. There is no `network.source` (or `networkSource`) property on ``ConvertConfiguration``; the iOS SDK selects its delivery path internally.

Override only the fields you need — every argument except `sdkKey` has a default, so you name just the ones you change:

```swift
import ConvertSwiftSDK

let config = ConvertConfiguration(
    sdkKey: "your-sdk-key",
    logLevel: .debug,
    networkTracking: false
)
let sdk = ConvertSwiftSDK(configuration: config)
```

### Await readiness

``ConvertSwiftSDK/ready()`` suspends until the first configuration is available — from a live fetch or a cache, including a cold start while offline:

```swift
try await sdk.ready()
```

It throws only on an unrecoverable configuration error (an empty SDK key, or empty/invalid direct-data). A transient network failure does not throw — the SDK resolves degraded and serves a cached config if one exists. To detect a failed or slow start, see <doc:FailureDetection>.

### Create a context

A context carries the visitor identity. Pass a `visitorId`, or omit it for a persistent auto-generated UUID (never the IDFA or IDFV):

```swift
let context = sdk.createContext()
```

The auto-generated visitor ID is stored in the Keychain and reused on every subsequent launch, so the same device buckets consistently across app launches. Same-install continuity is guaranteed. Continuity **across an uninstall and reinstall is best-effort only**: the Keychain item may survive an app's removal on some iOS versions and backup configurations, but the OS does not guarantee it — a reinstall can surface a fresh visitor ID. Do not depend on a stable ID across reinstalls; depend on it only within an install. (The item is written `…ThisDeviceOnly`, so it never syncs to the user's other devices via iCloud Keychain.)

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

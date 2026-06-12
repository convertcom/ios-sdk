# ``ConvertSDK``

A/B testing, feature flags, segmentation, and conversion tracking for iOS, iPadOS, tvOS, and macOS.

## Overview

Initialize the SDK, await its first configuration, create a visitor context, decide, and track:

```swift
import ConvertSDK

let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
try await sdk.ready()                                   // suspends until config is available

let context = sdk.createContext()                       // visitorId optional → persistent auto-UUID

if let variation = await context.runExperience("pricing-test") {
    // switch your UI on the variation key, e.g. "variant-a"
    print("Variation \(variation.key)")
}

await context.trackConversion("purchase-goal", goalData: [.amount: .double(49.99)])
```

The one ordering rule is ``ConvertSDK/ready()`` before deciding; everything else is order-independent. Decisioning never throws — ``ConvertContext/runExperience(_:enableTracking:)`` returns `nil` when the visitor is ineligible, the experience is unknown, or the SDK is not yet ready. Only ``ConvertSDK/ready()`` throws, and only on an unrecoverable configuration error.

### Working offline and in the background

Bucketing is deterministic and offline-capable: once a config is cached, decisions resolve with no network. Tracking events queue on disk and flush — including after the app is suspended or terminated — over a background `URLSession`. See <doc:OfflineAndBackgroundDelivery>.

### Detecting a failed or slow start

There is no typed error event to observe. A failed or slow initialization is detected through the log stream and a readiness timeout. See <doc:FailureDetection>.

### Differences from the JavaScript and Android SDKs

These are deliberate, Swift-idiomatic choices, named so they are never a silent surprise:

- The SDK is constructed with ``ConvertSDK/init(configuration:)``, not a `builder(...)` chain (the Android pattern). The public method names — ``ConvertSDK/ready()``, ``ConvertSDK/createContext(visitorId:attributes:)``, ``ConvertContext/runExperience(_:enableTracking:)``, ``ConvertContext/runFeature(_:enableTracking:)``, ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)``, ``ConvertSDK/on(_:callback:)`` / ``ConvertSDK/off(_:)`` — match the JavaScript SDK exactly.
- Constants use `lowerCamelCase` (Swift convention) rather than the upper-cased forms used elsewhere.
- There is no Objective-C interop surface; the API is Swift-only.

## Topics

### Essentials

- ``ConvertSDK``
- ``ConvertSDK/init(configuration:)``
- ``ConvertSDK/ready()``
- ``ConvertSDK/createContext(visitorId:attributes:)``
- <doc:GettingStarted>

### Deciding

- ``ConvertContext``
- ``ConvertContext/runExperience(_:enableTracking:)``
- ``ConvertContext/runExperiences(enableTracking:)``
- ``ConvertContext/runFeature(_:enableTracking:)``
- ``ConvertContext/runFeatures(enableTracking:)``
- ``Variation``
- ``BucketedFeature``

### Tracking

- ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)``
- ``GoalData``

### Observing

- ``ConvertSDK/on(_:callback:)``
- ``ConvertSDK/off(_:)``
- ``SystemEvent``

### Configuration

- ``ConvertConfiguration``
- ``Segments``
- ``ConvertContext/setDefaultSegments(_:)``
- ``ConvertContext/setCustomSegments(_:)``
- ``LogLevel``
- ``ConvertError``

### Guides

- <doc:GettingStarted>
- <doc:OfflineAndBackgroundDelivery>
- <doc:FailureDetection>
- <doc:Privacy>

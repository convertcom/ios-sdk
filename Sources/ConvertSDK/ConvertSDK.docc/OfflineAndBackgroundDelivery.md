# Offline and Background Delivery

How decisions resolve offline and how tracking events survive suspension and termination.

## Overview

The SDK is built to keep working when the network is not. Two behaviors make that true: deterministic offline bucketing, and a durable event queue that flushes in the background.

> Warning: Do **not** initialize the SDK from an app extension in v1. App-extension use is out of scope for this release and is unsupported. An extension runs in a separate process with its own sandbox, so it does not share the SDK's on-disk config cache or event queue — initializing from an extension **silently breaks cross-process persistence**: there is no error, but cached config and queued events do not carry between your app and its extension. Initialize the SDK only from your main app process.

### Deciding offline

Once a configuration has been cached, ``ConvertContext/runExperience(_:enableTracking:)`` and ``ConvertContext/runFeature(_:)`` resolve with no network call. Bucketing is deterministic and sticky — the same visitor buckets into the same ``Variation`` across sessions and across launches, online or offline. On a cold start while offline, ``ConvertSDK/ready()`` resolves from the cached config rather than hanging.

If repeated configuration refreshes fail, the SDK keeps serving the last-good config indefinitely and emits a `[WARN]` line. Stale config is a warning, not a failure — bucketing never breaks.

### Delivering events in the background

Tracking events do not require connectivity at the call site. A conversion enqueued through ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)`` is written to an on-disk queue and batched for delivery.

When the app is suspended or terminated before the queue drains, the pending batch ships over a background `URLSession` so the OS can complete the upload after your process is gone. On the next launch, the SDK recovers any events the previous process persisted and arms them for the next flush — so events are not lost across a termination, with no integrator wiring required.

For prompt background-wake completion, you may forward your app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the SDK. This is optional: the SDK reconciles persisted uploads on the next initialization regardless, so an integrator that never wires it loses no events.

### The bounded data-loss boundary

The recovery guarantee has one documented edge. If the on-disk queue file is present but its bytes fail to decode — a partial write from an unexpected kill, or external corruption — the SDK discards that file, logs a `[WARN]` line, re-initializes an empty queue, and continues. The events that were inside that corrupt batch are lost; nothing else is. The SDK self-heals rather than crashing or refusing to start, so the failure is bounded to a single corrupt batch. (A *missing* queue file — the normal state on a first launch or right after a successful flush cleared it — is not corruption: it is treated as an empty queue silently, with no warning.)

### Controlling tracking

Two independent mechanisms suppress event **delivery**. In both cases bucketing is unaffected — decisions still resolve, and only the sending of events is suppressed.

1. **Static — the whole SDK.** Set ``ConvertConfiguration/networkTracking`` to `false` in the configuration. No tracking events are enqueued for delivery for the lifetime of that SDK instance:

   ```swift
   import ConvertSDK

   // STATIC suppression: no event is ever delivered, but bucketing still resolves.
   let config = ConvertConfiguration(sdkKey: "your-sdk-key", networkTracking: false)
   let sdk = ConvertSDK(configuration: config)
   try await sdk.ready()
   let context = sdk.createContext()
   let variation = await context.runExperience("pricing-test")
   print("decided: \(variation?.key ?? "none")")  // still buckets; nothing is tracked
   ```

2. **Dynamic — a single call.** Pass `enableTracking: false` to ``ConvertContext/runExperience(_:enableTracking:)``, ``ConvertContext/runFeature(_:enableTracking:)``, ``ConvertContext/runExperiences(enableTracking:)``, or ``ConvertContext/runFeatures(enableTracking:)``. That call buckets the visitor but emits no exposure event for that decision:

   ```swift
   import ConvertSDK

   // DYNAMIC suppression: this one call buckets but emits no exposure event.
   let variation = await context.runExperience("pricing-test", enableTracking: false)
   print("decided: \(variation?.key ?? "none")")
   ```

   The per-call flag is combined with the static flag: an exposure event is delivered only when `networkTracking` is `true` **and** the call's `enableTracking` is `true`.

There is no separate opt-out API. To not track, either do not initialize the SDK at all, or suppress delivery with one of the two flags above.

> Important: The static ``ConvertConfiguration/networkTracking`` flag gates **new** event enqueues. It is not an in-flight kill-switch — events already queued, and conversion events, behave per their shipped delivery semantics. Treat it as "stop enqueuing new events," not "purge everything currently in the pipe."

### Why the delivery succeeds in reports

The SDK sets a `ConvertAgent/<version>` User-Agent on both the foreground and background delivery paths, and that header cannot be overridden. This is deliberate: the Convert metrics endpoint silently discards events sent with a default User-Agent. Locking the header guarantees your queued events are recorded rather than accepted-and-dropped.

### See also

For the full integration path, see <doc:GettingStarted>. To detect a failed or slow start, see <doc:FailureDetection>.

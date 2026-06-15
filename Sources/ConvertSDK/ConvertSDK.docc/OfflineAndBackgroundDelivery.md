# Offline and Background Delivery

How decisions resolve offline and how tracking events survive suspension and termination.

## Overview

The SDK is built to keep working when the network is not. Two behaviors make that true: deterministic offline bucketing, and a durable event queue that flushes in the background.

### Deciding offline

Once a configuration has been cached, ``ConvertContext/runExperience(_:enableTracking:)`` and ``ConvertContext/runFeature(_:)`` resolve with no network call. Bucketing is deterministic and sticky — the same visitor buckets into the same ``Variation`` across sessions and across launches, online or offline. On a cold start while offline, ``ConvertSDK/ready()`` resolves from the cached config rather than hanging.

If repeated configuration refreshes fail, the SDK keeps serving the last-good config indefinitely and emits a `[WARN]` line. Stale config is a warning, not a failure — bucketing never breaks.

### Delivering events in the background

Tracking events do not require connectivity at the call site. A conversion enqueued through ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)`` is written to an on-disk queue and batched for delivery.

When the app is suspended or terminated before the queue drains, the pending batch ships over a background `URLSession` so the OS can complete the upload after your process is gone. On the next launch, the SDK recovers any events the previous process persisted and arms them for the next flush — so events are not lost across a termination, with no integrator wiring required.

For prompt background-wake completion, you may forward your app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the SDK. This is optional: the SDK reconciles persisted uploads on the next initialization regardless, so an integrator that never wires it loses no events.

### Why the delivery succeeds in reports

The SDK sets a `ConvertAgent/<version>` User-Agent on both the foreground and background delivery paths, and that header cannot be overridden. This is deliberate: the Convert metrics endpoint silently discards events sent with a default User-Agent. Locking the header guarantees your queued events are recorded rather than accepted-and-dropped.

### See also

For the full integration path, see <doc:GettingStarted>. To detect a failed or slow start, see <doc:FailureDetection>.

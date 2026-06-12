# Detecting a Failed or Slow Start

How to tell a healthy initialization from a failed or hung one, when there is no error to catch.

## Overview

The SDK's reliability contract is to never crash the host and never throw across the API boundary. Internal faults become safe degraded results: a decision returns `nil` or a disabled feature, a delivery failure re-persists, corrupt data is discarded and the store re-initialized. The cost of that safety is silence — a failure does not announce itself through a typed event.

The ``SystemEvent`` set is frozen for cross-SDK parity, so there is no `.error` case to subscribe to. A failed or slow start surfaces three ways instead: a return value (`nil` / a disabled feature), a thrown error where one is idiomatic (only ``ConvertSDK/ready()`` throws), and the log stream. The recommended detection pattern combines the log stream with a readiness timeout.

### The pattern: log stream plus a readiness timeout

Treat a `[WARN]` or `[ERROR]` log line that lands *before* the first ready signal as a configuration failure, and bound the wait so a silent network hang flips to a visible failure instead of an infinite spinner. A 10-second readiness timeout is the established value.

The log level is always a leading text token in the line (`[WARN]`, `[ERROR]`), so it survives VoiceOver, log export, and Console.app filtering. Watch for lines at ``LogLevel/warn`` and ``LogLevel/error`` during startup.

### Observing the ready signal

``ConvertSDK/ready()`` fires the ``SystemEvent/ready`` event exactly once and never re-fires on a later config refresh. Subscribe with ``ConvertSDK/on(_:callback:)`` to learn when the SDK becomes usable, and pair it with a timeout:

```swift
let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))

// Race readiness against a 10-second timeout: whichever finishes first wins.
let started = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        do { try await sdk.ready(); return true }   // resolved (live, cached, or degraded)
        catch { return false }                       // unrecoverable configuration error
    }
    group.addTask {
        try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
        return false                                 // 10s elapsed → treat as a failed/slow start
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}

if started {
    // config is in memory — proceed to createContext and decide
} else {
    // surface a failure with a message + hint, e.g. "Check network + SDK key"
}
```

Equivalently, observe the ready event explicitly:

```swift
let token = await sdk.on(.ready) { _ in
    // the SDK is ready exactly once; tear down your readiness timer here
}
// later, when finished observing:
await sdk.off(token)
```

### What "ready" does and does not mean

A resolved ``ConvertSDK/ready()`` means a config is available — it may be a live fetch, a cache hit, or a degraded resolution with no config at all (when both live and cache are unavailable). After ready, a `[WARN]` from a failed background refresh is *not* a regression: the SDK keeps serving the last-good config. Only a warning or error that arrives *before* the first ready signal indicates the initial configuration never loaded.

### See also

For the full integration path, see <doc:GettingStarted>. For how queued events survive suspension, see <doc:OfflineAndBackgroundDelivery>.

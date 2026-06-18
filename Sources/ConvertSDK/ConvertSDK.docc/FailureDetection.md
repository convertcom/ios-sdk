# Detecting a Failed or Slow Start

How to tell a healthy initialization from a failed or hung one, when there is no error to catch.

## Overview

The SDK's reliability contract is to never crash the host and never throw across the API boundary. Internal faults become safe degraded results: a decision returns `nil` or a disabled feature, a delivery failure re-persists, corrupt data is discarded and the store re-initialized. The cost of that safety is silence — a failure does not announce itself through a typed event.

The ``SystemEvent`` set is **frozen** for cross-SDK parity (FR52), and that is a deliberate parity break with a real, named cost: there is **no `.error` case**, so you **cannot** write `on(.error)` to be notified of a failure the way an event-driven API might let you. This is not an oversight — the event set is held identical across the iOS, JavaScript, and Android SDKs, and none of them expose a typed error event. The cost is that failures are not pushed to you; you have to look for them.

A failed or slow start therefore surfaces only three ways: a **return value** (`nil` / a disabled feature), a **thrown ``ConvertError``** where one is idiomatic (only ``ConvertSDK/ready()`` throws), and the **log stream**. The mitigation for the missing error event is the detection pattern below, which combines the log stream with a readiness timeout.

### The pattern: log stream plus a readiness timeout

Treat a `[WARN]` or `[ERROR]` log line that lands *before* the first ready signal as a configuration failure, and bound the wait so a silent network hang flips to a visible failure instead of an infinite spinner. A 10-second readiness timeout is the established value.

The log level is always a leading text token in the line (`[WARN]`, `[ERROR]`), so it survives VoiceOver, log export, and Console.app filtering. Watch for lines at ``LogLevel/warn`` and ``LogLevel/error`` during startup.

### Observing the ready signal

``ConvertSDK/ready()`` fires the ``SystemEvent/ready`` event exactly once and never re-fires on a later config refresh. Subscribe with ``ConvertSDK/on(_:callback:)`` to learn when the SDK becomes usable, and pair it with a timeout.

The timeout must run **concurrently** with — not structurally around — the ``ConvertSDK/ready()`` await. ``ConvertSDK/ready()`` is **not** cancellation-aware: it resumes only when config resolves (live, cache, or degraded) or an unrecoverable error is signalled, and on a network hang with no cache that resolution arrives only after the SDK's 30-second request timeout. Do **not** wrap the two in a `withTaskGroup`: a task group implicitly awaits *all* of its children before the `await` on the group returns, and cancelling the non-cancellable ``ConvertSDK/ready()`` child does not make it finish early — so the group would block ~30 s before the 10 s timeout could take effect, which is the very infinite-spinner this section warns against.

Instead, drive a small state flag from two writers — the ``ConvertSDK/ready()`` await and a concurrent timeout `Task` — and let the **first** terminal transition win:

```swift
enum Readiness { case loading, ready, failed(reason: String) }

actor ReadinessGate {
    private(set) var state: Readiness = .loading
    /// First terminal transition wins; later writers no-op.
    func resolve(_ next: Readiness) {
        if case .loading = state { state = next }
    }
    var current: Readiness { state }
}

let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
let gate = ReadinessGate()

// Concurrent 10s timeout: flips to a visible failure if `ready()` has not resolved
// yet. `Task.sleep(nanoseconds:)` (not the iOS 16+ `Task.sleep(for:)`) keeps the
// iOS 15 deployment floor.
let timeoutTask = Task {
    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
    await gate.resolve(.failed(reason: "Configuration fetch timed out."))
}

do {
    try await sdk.ready()                 // resolved: live, cached, or degraded
    timeoutTask.cancel()
    await gate.resolve(.ready)
} catch {
    timeoutTask.cancel()                  // unrecoverable configuration error
    await gate.resolve(.failed(reason: error.localizedDescription))
}

switch await gate.current {
case .ready:
    break  // config is in memory — proceed to createContext and decide
case .failed(let reason):
    break  // surface `reason` (message + hint), e.g. "Configuration fetch timed out."
case .loading:
    break  // unreachable: one of the two writers above has resolved the gate
}
```

On the timeout-wins path the still-suspended ``ConvertSDK/ready()`` await is left to complete in the background ~30 s later (it cannot be cancelled). That late completion is harmless: its `gate.resolve(.ready)` finds the gate already `.failed` and no-ops — no incorrect late state change and no crash.

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

### The diagnostic voice and log-line format

Every diagnostic the SDK produces follows one voice: **state what happened, then give an actionable hint** — never a bare code, a lone "error," or a raw stack trace. The same voice holds on all three failure surfaces (UX-DR18): the **return value** (`nil` / a disabled feature), the **log line**, and the thrown ``ConvertError``'s `errorDescription`.

The examples below illustrate the *pattern* the SDK applies across log lines and return-value diagnostics — they are the voice contract, not literal verbatim API output:

| Do (message → hint) | Don't |
|---|---|
| "No variation for experience `pricing-test`." → "Check experience config or audience eligibility." | "Bucketing failed." |
| "Goal not found: `purchase-goal`." → "Verify the goal is configured in your Convert project." | "Invalid goal." |
| "Configuration fetch timed out." → "Check network + SDK key." | "Error 0x…" / a raw stack trace |

On the **thrown-error** surface, the two ``ConvertError`` cases that actually ship are the concrete examples of this voice. Their exact `errorDescription` strings are:

- `.invalidConfiguration(detail)` → `"Invalid SDK configuration: \(detail). Verify the configuration struct fields."`
- `.invalidSdkKey(detail)` → `"Structurally invalid SDK key: \(detail). Verify the key in your Convert dashboard."`

Each is *what happened* followed by *what to do* — the same shape as the illustrative table.

```swift
import ConvertSDK

func _demo() async throws {
    let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
    do {
        try await sdk.ready()
    } catch let error as ConvertError {
        // errorDescription carries the message + actionable hint, e.g.
        // "Invalid SDK configuration: <detail>. Verify the configuration struct fields."
        print(error.errorDescription ?? "unknown error")
    }
}
```

**Log-line format.** Every log line is composed as `[LEVEL] {Type}.{method}: {message}` (UX-DR19). The level is a **leading text token** — `[WARN]`, `[ERROR]` — never color-only, so it survives VoiceOver, log export, and Console.app filtering. A real example from a deduped conversion:

```
[WARN] ConvertContext.trackConversion: goal '100435728' already tracked for visitor, skipping.
```

The `'100435728'` is the goal's **ID** (the numeric wire identifier from your project config), not the goal *key* you passed to ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)``. The dedup line reports the ID because dedup is keyed on it; by contrast the *goal-not-found* line reports the **key** you passed (`goal '<your-key>' not found in config, dropping.`). When filtering logs, match the dedup line on the goal ID and the not-found line on the key.

The levels, in ascending severity, map to ``LogLevel``:

| Token | ``LogLevel`` | Meaning |
|---|---|---|
| `ERROR` | ``LogLevel/error`` | An SDK-breaking failure. |
| `WARN` | ``LogLevel/warn`` | A recoverable problem or degraded (non-throwing) outcome. |
| `INFO` | ``LogLevel/info`` | Routine lifecycle and state transitions. |
| `DEBUG` | ``LogLevel/debug`` | Diagnostic detail while debugging an integration. |
| `TRACE` | ``LogLevel/trace`` | Fine-grained internal control-flow tracing. |
| *(silent)* | ``LogLevel/silent`` | Mutes all output. |

The **default ship level is ``LogLevel/warn``** — quieter than the JavaScript SDK's `TRACE` default, so production builds suppress `trace`, `debug`, and `info` unless you explicitly lower the threshold. Lower it while diagnosing an integration:

```swift
import ConvertSDK

func _demo() async throws {
    // Lower from the default `.warn` to `.debug` while diagnosing an integration.
    let config = ConvertConfiguration(sdkKey: "your-sdk-key", logLevel: .debug)
    let sdk = ConvertSDK(configuration: config)
    try await sdk.ready()
    _ = sdk
}
```

**Secret-safety guarantee.** Logging never leaks credentials. Every logged string routes through the SDK's `toLoggable` masking, which guarantees:

- `sdkKey` is **masked** as `sk_…<last4>` — only the final four characters of the key material appear.
- `sdkKeySecret` is **never logged at any level**, including ``LogLevel/debug`` and ``LogLevel/trace``.
- secret-bearing query strings (`sdkKey=…`, `sdkKeySecret=…`) have their **values stripped** from any logged URL.

You can safely raise verbosity to `.debug` or `.trace` in a build without risking a credential ending up in a log export.

### The locked User-Agent and empty reports

One failure looks healthy but records nothing: events POST with `200 OK`, no warning is logged, yet reports stay empty. That is the locked `ConvertAgent/<version>` User-Agent being rewritten by a networking layer outside the SDK. It is a frequent and expensive trap — see the dedicated entry in <doc:Troubleshooting> ("Delivery succeeds but nothing appears in reports").

### See also

For common symptoms mapped to causes, see <doc:Troubleshooting>. For the full integration path, see <doc:GettingStarted>. For how queued events survive suspension, see <doc:OfflineAndBackgroundDelivery>.

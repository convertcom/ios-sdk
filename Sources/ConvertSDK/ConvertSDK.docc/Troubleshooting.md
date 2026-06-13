# Troubleshooting

Concrete symptoms, their usual cause, and where to look — for the cases that surface as a quiet `nil`, an empty report, or a single log line rather than a thrown error.

## Overview

The SDK never crashes the host and never throws across the decisioning boundary. The cost of that safety is that most problems surface quietly: a return value of `nil`, a dropped event, or a single line in the log stream — not an exception you can catch. This guide maps the symptoms a developer actually sees to the underlying cause, so a quiet degradation does not get mistaken for "working."

Each entry names the symptom, explains the cause, and points at the log line or guide that confirms it. For the general detection pattern (a readiness timeout plus watching the log stream), see <doc:FailureDetection>.

### Delivery succeeds but nothing appears in reports

This is the most expensive silent failure to diagnose, because every signal says the integration is healthy: events POST without error, the endpoint returns `200 OK`, and no warning is logged — yet the reports stay empty.

The cause is almost always a **networking layer that rewrites the `User-Agent` header**. The SDK stamps a non-overridable `User-Agent: ConvertAgent/<version>` on *both* delivery paths — the foreground per-request transport and the background `URLSession` (via `httpAdditionalHeaders`). The Convert metrics endpoint **silently discards** any event that arrives with a default (Foundation/`URLSession`) User-Agent: it still returns `200 OK` and drops the body. So an integration sending with the wrong User-Agent looks exactly like a healthy one — 200 responses, no errors — while nothing is recorded.

The locked header is a protection, not a limitation: it guarantees your queued events are *recorded* rather than accepted-and-dropped. The SDK cannot be made to send a different User-Agent; if reports are empty while delivery "succeeds," the rewrite is happening **outside** the SDK — a forward proxy, a VPN, an MDM network filter, or an analytics/observability shim that normalizes outbound headers. Check those layers for a User-Agent override and exempt the Convert metrics host.

For the full explanation of why the locked header is what makes delivery count in reports, see the "Why the delivery succeeds in reports" section of <doc:OfflineAndBackgroundDelivery>.

### The app hangs on startup, or the spinner never resolves

A silent network hang during the initial configuration fetch does not announce itself — ``ConvertSDK/ready()`` simply stays suspended, and any UI gated on it spins forever. The fix is to bound the wait so a hang flips into a visible failure instead of an infinite spinner.

Apply a **10-second readiness timeout**: race ``ConvertSDK/ready()`` against a timeout and treat whichever finishes first as the outcome. The ready/timeout pattern is in <doc:FailureDetection>.

While you wait, watch the log stream: a `[WARN]` or `[ERROR]` line that lands **before** the first ready signal indicates the initial configuration never loaded — that is a configuration failure (bad SDK key, unreachable endpoint), not a transient one. A warning that arrives *after* ready is not a regression; the SDK keeps serving the last-good config.

### `runExperience` returns `nil`

A `nil` from ``ConvertContext/runExperience(_:enableTracking:)`` is **not an error** — it is the documented "no decision" result, and it has three ordinary causes:

- **The visitor is ineligible** for that experience (audience targeting excluded them).
- **The experience key is unknown** — a typo, or an experience that is not live in the config.
- **The SDK is not ready yet** — `runExperience` was called before ``ConvertSDK/ready()`` resolved, so no config was in memory to decide against.

Confirm which by checking the log stream for a `[WARN]` line at the time of the call. The one ordering rule is to `await ready()` before deciding; everything else is order-independent.

### Goal not found, or a conversion is not recorded

Two distinct cases both surface quietly — neither ever throws:

- **Unknown goal key.** Calling ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)`` with a goal key that is not in your project config logs a `[WARN]` line of the form `goal '<key>' not found in config, dropping.` and drops the conversion. Verify the goal key exists in your Convert dashboard. (A pre-ready call logs `SDK not ready, dropping conversion for goal '<key>'.` instead.)

- **A repeat conversion is suppressed.** Conversions **dedup per visitor + goal**: once a visitor has converted on a goal, a second `trackConversion` for that same goal is intentionally suppressed and logs `goal '<key>' already tracked for visitor, skipping.` This is deliberate, not a bug. To record a genuine repeat — a second purchase by the same visitor — pass `forceMultipleTransactions: true`:

  ```swift
  import ConvertSDK

  func _demo() async throws {
      let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
      try await sdk.ready()
      let context = sdk.createContext()
      // A repeat conversion for the same goal + visitor is deduped (suppressed) by default.
      // Pass forceMultipleTransactions: true for a deliberate repeat purchase.
      await context.trackConversion(
          "purchase-goal",
          goalData: [.amount: .double(49.99)],
          forceMultipleTransactions: true
      )
  }
  ```

### Reading the diagnostic log

Because failures surface through the log stream rather than thrown errors, knowing the log format makes diagnosis fast. The format, levels, default ship level, and the secret-masking guarantees are documented in <doc:FailureDetection> under "The diagnostic voice and log-line format."

### See also

For the detection pattern (readiness timeout plus log stream) and the diagnostic voice, see <doc:FailureDetection>. For background delivery and the locked User-Agent, see <doc:OfflineAndBackgroundDelivery>. For the full integration path, see <doc:GettingStarted>.

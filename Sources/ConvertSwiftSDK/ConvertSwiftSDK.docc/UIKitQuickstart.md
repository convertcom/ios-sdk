# UIKit Quickstart

Wire the SDK into a `UIViewController` with the completion-handler overloads: initialize, await readiness in a callback, run experiences, switch a `UILabel` on the variation key, and track a conversion on a button tap.

## Overview

This is the completion-handler path for call sites that are not on structured concurrency. Two overloads bridge the `async` core to a callback: ``ConvertSwiftSDK/ready(completion:)`` and ``ConvertContext/runExperiences(enableTracking:completion:)``. Both deliver their result **on the `MainActor`**, so a completion handler can read its result and touch UIKit views directly — no manual `DispatchQueue.main.async` hop. A SwiftUI integration that prefers `async`/`await` is covered in <doc:SwiftUIQuickstart>.

The async/await API and these completion-handler overloads reach **identical behavior** — same bucketing, same tracking, same degraded results. The choice is idiom, not capability: pick whichever fits your call site.

The path below is Journey 1: construct → ready → context → decide → switch a view → track. The first run produces a bucketing entry and a conversion in Convert's Live Logs.

### Initialize and decide from a view controller

Construct the SDK in `viewDidLoad`. The initializer never blocks or throws. Call ``ConvertSwiftSDK/ready(completion:)`` and, on `.success`, create a context and call ``ConvertContext/runExperiences(enableTracking:completion:)``. Because the SDK exposes a plural overload, you receive `[Variation]` and select the one experience you care about with `first(where:)` on ``Variation/experienceKey``; then switch the label on ``Variation/key``:

```swift
import ConvertSwiftSDK
import UIKit

final class PricingViewController: UIViewController {
    private let priceLabel = UILabel()
    private var context: ConvertContext?

    override func viewDidLoad() {
        super.viewDidLoad()
        let sdk = ConvertSwiftSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))

        sdk.ready { [weak self] result in                    // delivered on the MainActor
            guard let self else { return }
            switch result {
            case .success:
                let context = sdk.createContext()            // visitorId optional → persistent auto-UUID
                self.context = context
                context.runExperiences { variations in       // MainActor — touch UIKit directly
                    let pricing = variations.first(where: { $0.experienceKey == "pricing-test" })
                    switch pricing?.key {
                    case "variant-a":
                        self.priceLabel.text = "Annual plan — $49.99"
                    case "variant-b":
                        self.priceLabel.text = "Limited-time offer — $39.99"
                    default:
                        self.priceLabel.text = "Standard plan — $59.99"   // no match → control
                    }
                }
            case .failure:
                self.priceLabel.text = "Standard plan — $59.99"           // unrecoverable config → control
            }
        }
    }
}
```

Both callbacks arrive on the `MainActor`, so the `priceLabel.text` assignments run on the main thread with no extra dispatch. `ready` is the one call that surfaces a `.failure`, and only on an unrecoverable configuration error (an empty SDK key, or empty/invalid direct-data); a transient network failure resolves `.success` against a cached config instead.

An empty `variations` array, or a non-matching ``Variation/experienceKey``, leaves `pricing` as `nil` and the `default` arm renders the control. That is a valid degraded result, not an error — the visitor was ineligible, the experience key was unknown, or the SDK was not ready. Never force-unwrap the result; the `default` arm and the `??` / `first(where:)` patterns keep every path crash-free.

### Track a conversion from a button action

Wire a "Buy" button to an `@objc` action with `addTarget(_:action:for:)`. ``ConvertContext/trackConversion(_:goalData:forceMultipleTransactions:)`` is `async`-only — there is no completion overload — so call it inside a `Task` from the action. An optional ``GoalData`` map carries metrics such as a revenue ``GoalDataKey/amount``:

```swift
import ConvertSwiftSDK
import UIKit

final class CheckoutViewController: UIViewController {
    private let buyButton = UIButton(type: .system)
    private var context: ConvertContext?

    override func viewDidLoad() {
        super.viewDidLoad()
        buyButton.setTitle("Buy", for: .normal)
        buyButton.addTarget(self, action: #selector(buyTapped), for: .touchUpInside)
    }

    @objc private func buyTapped() {
        guard let context else { return }                    // not ready yet → no-op, never a crash
        Task {
            await context.trackConversion(
                "purchase-goal",
                goalData: [.amount: .double(49.99)]
            )
        }
    }
}
```

An unknown goal key logs a `[WARN]` line and is dropped — `trackConversion` never throws. The `guard let context` keeps the tap a safe no-op if a user taps before readiness resolved.

> Note: App-extension integration (widgets, share extensions, App Clips) is a **future addition**, not part of v1. The SDK's persistent visitor ID lives in the main app's Keychain; running it from a separate extension process silently breaks cross-process persistence and produces an inconsistent identity. Initialize and decide only from the main app target in v1.

> Important: A standalone UIKit sample app is **out of v1 scope**. A UIKit consumer is served by this quickstart plus the shared `URLProtocol` test suite under `Tests/ConvertSwiftSDKTests/` — start with `Tests/ConvertSwiftSDKTests/Support/URLProtocolStub.swift` and the adapter/integration tests, which exercise the completion-handler paths against the shared staging project for runnable reference behavior.

### Next steps

- <doc:SwiftUIQuickstart> — the same flow in a SwiftUI `App` with async/await.
- <doc:GettingStarted> — the full linear install → init → ready → decide → track walkthrough.

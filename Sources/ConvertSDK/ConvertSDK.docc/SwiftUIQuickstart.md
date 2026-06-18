# SwiftUI Quickstart

Wire the SDK into a SwiftUI `App` with async/await: initialize at app scope, await readiness, run an experience, switch a view on the variation key, and track a conversion on a tap.

## Overview

This is the structured-concurrency path. The SDK's deciding API is `async` — `await sdk.ready()`, `await ctx.runExperience(_:)`, `await ctx.trackConversion(_:goalData:)` — which fits SwiftUI's `.task {}` modifier and `async` view models with no callback layer. A UIKit integration that prefers completion handlers is covered in <doc:UIKitQuickstart>; both reach identical behavior.

The path below is Journey 1: construct → ready → context → decide → switch a view → track. The first run produces a bucketing entry and a conversion in Convert's Live Logs.

### Initialize at app scope

Construct the SDK once and hold it on an `@StateObject` view model so it survives view redraws. The initializer never blocks or throws, so it is safe to call from a synchronous `init`. Await readiness from a `.task {}` — `ready()` is the one call that can throw, and only on an unrecoverable configuration error:

```swift
import ConvertSDK
import SwiftUI

@MainActor
final class ConvertModel: ObservableObject {
    let sdk = ConvertSDK(configuration: ConvertConfiguration(sdkKey: "your-sdk-key"))
    @Published private(set) var variationKey: String?

    func start() async {
        do {
            try await sdk.ready()                       // throws only on unrecoverable config
        } catch {
            return                                      // stay on control; never crash
        }
        let context = sdk.createContext()               // visitorId optional → persistent auto-UUID
        variationKey = await context.runExperience("pricing-test")?.key
    }
}

@main
struct DemoApp: App {
    @StateObject private var model = ConvertModel()

    var body: some Scene {
        WindowGroup {
            PricingView()
                .environmentObject(model)
                .task { await model.start() }           // drive readiness + decision off the main run loop
        }
    }
}
```

Decisioning is gated on readiness: `variationKey` stays `nil` until `runExperience` resolves, so the UI renders control until the assignment lands. There is no blocking spinner — the control view *is* the loading state.

### Switch a view on the variation key

`runExperience` returns an optional ``Variation``. Switch the rendered subview on `variation?.key`; the `default` arm covers both the `nil` (degraded) case and any unrecognized key, so every code path renders something:

```swift
import ConvertSDK
import SwiftUI

struct PricingView: View {
    @EnvironmentObject private var model: ConvertModel

    var body: some View {
        switch model.variationKey {
        case "variant-a":
            PriceCard(headline: "Annual plan", price: 49.99)
        case "variant-b":
            PriceCard(headline: "Limited-time offer", price: 39.99)
        default:
            PriceCard(headline: "Standard plan", price: 59.99)   // nil or unknown key → control
        }
    }
}
```

A `nil` variation is a valid degraded result, not an error — the visitor was ineligible, the experience key was unknown, or the SDK was not ready. None of those is a thrown error and none should change how the screen behaves: it renders the control. Never force-unwrap the variation, and never gate the screen behind a spinner waiting for a non-`nil` result.

### Track a conversion on a tap

Call `trackConversion` from the "Buy" action. It is `async`, so wrap it in a `Task` inside the button closure. An optional ``GoalData`` map carries metrics such as a revenue ``GoalDataKey/amount``:

```swift
import ConvertSDK
import SwiftUI

struct PriceCard: View {
    @EnvironmentObject private var model: ConvertModel
    let headline: String
    let price: Double

    var body: some View {
        VStack {
            Text(headline)
            Text(price, format: .currency(code: "USD"))
            Button("Buy") {
                Task {
                    let context = model.sdk.createContext()
                    await context.trackConversion(
                        "purchase-goal",
                        goalData: [.amount: .double(price)]
                    )
                }
            }
        }
    }
}
```

An unknown goal key logs a `[WARN]` line and is dropped — `trackConversion` never throws.

> Note: App-extension integration (widgets, share extensions, App Clips) is a **future addition**, not part of v1. The SDK's persistent visitor ID lives in the main app's Keychain; running it from a separate extension process silently breaks cross-process persistence and produces an inconsistent identity. Initialize and decide only from the main app target in v1.

### Next steps

- <doc:UIKitQuickstart> — the same flow from a `UIViewController` with completion-handler overloads.
- <doc:GettingStarted> — the full linear install → init → ready → decide → track walkthrough.

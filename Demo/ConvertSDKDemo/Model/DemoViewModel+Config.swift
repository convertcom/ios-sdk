import ConvertSDK
import Foundation
import Network

// MARK: - Config state machine, reset-visitor & connectivity (Story 7.6 / DEMO-6)

// This extension holds the Story 7.6 METHODS for ``DemoViewModel``: the ``ConfigState``
// readiness driver (``start()``), the reset-visitor affordance (``resetVisitor()``), the
// connectivity monitor (``startConnectivityMonitoring()``), and the Config-panel data
// accessors. The matching STORED state — ``DemoViewModel/configState``, the published
// ``DemoViewModel/context``, ``DemoViewModel/configuration``,
// ``DemoViewModel/lastResetVisitorMasked``, ``DemoViewModel/isOnline``, and the
// ``DemoViewModel/pathMonitor`` / ``DemoViewModel/pathMonitorQueue`` pair — stays on the main
// type because Swift fixes each type's memory layout at its main declaration, so stored
// properties cannot live in an extension. The methods moved here purely to keep
// `DemoViewModel.swift` under the 400-line `file_length` gate, exactly as
// `DemoViewModel+Inspector.swift` / `+Conversions.swift` already do.
//
// Access note (the rule the sibling extensions document): Swift `private`/`private(set)` do
// NOT reach a same-type extension in a *different* file. So the state this extension must WRITE
// — ``context`` (swapped by ``resetVisitor()``), ``configState``, ``lastResetVisitorMasked``,
// ``isOnline`` — is declared with an `internal` setter on the main type (no `private(set)` on
// the ones written here), and the keys/config it READS (``singleExperienceKey``,
// ``singleFeatureKey``, ``configuration``) are `internal`/non-`private` for the same reason.
// `internal` is the tightest level the cross-file compiler accepts; no code outside this type
// writes any of them, so it stays encapsulation-neutral.
//
// Concurrency note (``NWPathMonitor`` under `SWIFT_STRICT_CONCURRENCY: complete`):
// ``DemoViewModel`` is `@MainActor`, and `NWPathMonitor` is NOT `Sendable`. The monitor is held
// as a main-actor-isolated stored property and is only ever touched from the main actor —
// ``startConnectivityMonitoring()`` (a `@MainActor` method) calls `start(queue:)` on it. Its
// `pathUpdateHandler` is `@escaping @Sendable` and fires off the main actor on
// ``pathMonitorQueue``; the closure captures `self` weakly and hops back with
// `Task { @MainActor in … }` before writing ``isOnline``. Nothing crosses an actor boundary
// while non-`Sendable`, so NO `@unchecked Sendable` and NO `nonisolated(unsafe)` is required,
// and there are no force-unwraps. `NWPathMonitor` is iOS 12+, safe on the iOS 15 floor.

extension DemoViewModel {

    /// The maximum time ``start()`` waits for ``ConvertSDK/ready()`` before declaring the
    /// configuration load failed. Ten seconds, matching the Android SDK's readiness budget so the
    /// demos behave identically. A single named constant so the timeout never drifts between the
    /// race below and any future caller; expressed in seconds (``TimeInterval``).
    static let readinessTimeout: TimeInterval = 10

    /// Drives the ``ConfigState`` machine: awaits ``ConvertSDK/ready()`` directly while a
    /// concurrent timeout guards against a silent network hang, landing exactly one terminal state.
    ///
    /// `@MainActor` (inherited) so it mutates the published ``configState`` directly on the main
    /// actor. The structure is a simple, explicit race rather than a `withThrowingTaskGroup`: an
    /// unstructured timeout `Task` plus a direct `await ready()`, with the first terminal transition
    /// winning. `ready()` (``ConfigStore/waitForReady()``) IS cancellation-aware as of F-170 — its
    /// continuation is wrapped in `withTaskCancellationHandler` and de-registers the waiter on
    /// cancellation — so a `withThrowingTaskGroup` that cancels the `ready()` child on timeout would
    /// now ALSO honour the 10 s budget. This demo keeps the explicit-timeout shape for legibility
    /// (the readiness race reads in one place) and because, never cancelling the `ready()` await, it
    /// needs no task group. Either shape satisfies the "Failed within 10 s, no infinite spinner"
    /// contract; the timeout `Task` is what enforces the 10 s.
    ///
    /// Instead: a concurrent, unstructured ``readinessTimeout`` `Task` flips ``configState`` to a
    /// visible failure at 10 s, and `ready()` is awaited directly here. Both writers are guarded by
    /// an `if case .loading` check, so the FIRST terminal transition wins and the later one no-ops
    /// — which also preserves the post-`.loaded` no-downgrade rule. Outcomes:
    /// - `ready()` resolves first → ``ConfigState/loaded(fetchedAt:)`` stamped with the current
    ///   `Date` (the timeout `Task` is cancelled, so its sleep just exits quietly);
    /// - the 10 s timeout fires first → ``ConfigState/failed(reason:)`` with the timed-out message;
    /// - `ready()` THROWS a `ConvertError` → caught below, landing ``ConfigState/failed(reason:)``
    ///   carrying its `localizedDescription`.
    ///
    /// On the timeout-wins path the still-suspended `ready()` await is intentionally left to
    /// complete in the background ~30 s later (when the SDK's URLSession request times out). This
    /// demo does not cancel it — though it could, since `ready()` is cancellation-aware as of F-170.
    /// That late completion is harmless either way: its `if case .loading` guard finds ``configState``
    /// already `.failed`, so it no-ops — no incorrect late state change and no crash, just a quiet
    /// background completion of a lingering, by-design task.
    ///
    /// `Task.sleep(nanoseconds:)` (iOS 13+) is used — NOT the iOS 16+ `Task.sleep(for:)` — to stay
    /// on the iOS 15 floor. Connectivity monitoring is started here too (folded in so the app's
    /// `.task` and `ConvertSDKDemoApp.swift` stay untouched), BEFORE the await so the Offline
    /// banner reflects reality during the readiness wait.
    ///
    /// Kept named `start()` with the same `@MainActor`-async signature so the existing
    /// `ConvertSDKDemoApp.swift` `.task { await viewModel.start() }` call site compiles unchanged.
    func start() async {
        startConnectivityMonitoring()

        // Concurrent 10 s timeout: flips the UI to a visible failure if `ready()` has not resolved
        // yet, so a silent network hang can't leave an infinite spinner. It writes `configState`
        // directly (main-actor isolated) guarded by the still-`.loading` check, so the first
        // terminal transition wins. This uses an explicit timeout `Task` rather than a
        // `withThrowingTaskGroup` for legibility — see the doc comment. (`ready()` is now
        // cancellation-aware per F-170, so a cancelling task group would honour the 10 s too.)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readinessTimeout * 1_000_000_000))
            guard let self else { return }
            if case .loading = self.configState {
                self.configState = .failed(reason: "Configuration fetch timed out.")
            }
        }

        do {
            try await sdk.ready()
            timeoutTask.cancel()
            if case .loading = configState {
                configState = .loaded(fetchedAt: Date())
            }
        } catch {
            // `ready()` threw a `ConvertError`. Surface its actionable, redaction-safe
            // description verbatim — guarded so a timeout that already won is not downgraded.
            timeoutTask.cancel()
            if case .loading = configState {
                configState = .failed(reason: error.localizedDescription)
            }
        }
    }

    /// Starts observing connectivity so ``isOnline`` tracks the device's network path.
    ///
    /// `@MainActor` (inherited): assigns the `@Sendable` `pathUpdateHandler` and calls
    /// `start(queue:)` on the main-actor-held ``pathMonitor`` (touched only here). The handler
    /// fires off the main actor on ``pathMonitorQueue``, so it captures `self` weakly and hops
    /// back with `Task { @MainActor in … }` before writing the published ``isOnline`` — no actor
    /// boundary is crossed while non-`Sendable`, so no `@unchecked`/`nonisolated(unsafe)` and no
    /// force-unwrap is needed. Idempotent in practice: folded into ``start()``, which fires once
    /// from the app's `.task`. `path.status == .satisfied` is the online test (Network framework's
    /// canonical "has a usable path" signal).
    func startConnectivityMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Resets the demo to a brand-new visitor: swaps the sticky ``context`` for a fresh one and
    /// clears the per-visitor conversion dedup set.
    ///
    /// Synchronous and `@MainActor` (inherited). Steps:
    /// 1. mint a fresh visitor id (`UUID().uuidString`);
    /// 2. swap ``context`` for `sdk.createContext(visitorId:)` — the real public SDK API
    ///    (there is NO `reset()`/`resetVisitor()` on the SDK). Because ``context`` is `@Published`,
    ///    this swap republishes and every observing run screen re-renders against the new visitor;
    /// 3. ``clearTrackedGoals()`` (in `DemoViewModel+Conversions.swift`) empties the dedup set so
    ///    the same goal can convert fresh for the new visitor;
    /// 4. surface the new visitor id MASKED (PII-safe) via ``lastResetVisitorMasked`` so the Config
    ///    screen can confirm the reset without ever exposing the full UUID.
    func resetVisitor() {
        let newVisitorId = UUID().uuidString
        context = sdk.createContext(visitorId: newVisitorId)
        clearTrackedGoals()
        lastResetVisitorMasked = Self.maskedVisitorID(newVisitorId)
    }

    // MARK: - Config-panel accessors

    /// The SDK key as rendered for display, routed through the SDK's own ``toLoggable(_:)``
    /// redaction contract rather than a hand-rolled masker — so the demo shows EXACTLY what the
    /// SDK would log. `toLoggable` masks `sk_…`-form tokens to `sk_…<last4>`; the demo's
    /// account/project key ("10035569/10034190") has no `sk_` prefix, so it returns unchanged
    /// (honest — there is no secret to hide). A real `sk_…` key would be masked by the same path.
    var maskedSDKKey: String { toLoggable(configuration.sdkKey) }

    /// The configured environment label, or "default" when ``ConvertConfiguration/environment`` is
    /// `nil` (its default) — an honest label for "no named environment selected", not a fabricated
    /// value like "production".
    var environmentLabel: String { configuration.environment ?? "default" }

    /// Whether event/network tracking is enabled, read straight from
    /// ``ConvertConfiguration/networkTracking``.
    var trackingEnabled: Bool { configuration.networkTracking }

    /// The single value bundle the Config info panel (next task) renders, assembled from the
    /// accessors above plus the demo's target experience/feature keys. A small value type keeps
    /// the panel's input one testable struct rather than a scatter of computed props.
    var configPanelData: ConfigPanelData {
        ConfigPanelData(
            maskedKey: maskedSDKKey,
            environment: environmentLabel,
            experienceKey: Self.singleExperienceKey,
            featureKey: Self.singleFeatureKey,
            trackingEnabled: trackingEnabled
        )
    }

    /// Masks a visitor id to a non-identifying short prefix for display (PII-safe, NFR6).
    ///
    /// At most the first six characters followed by an ellipsis (e.g. `abc123…`), never the full
    /// UUID; an empty id reports `<none>`. A small `static` local here rather than reusing
    /// `DemoViewModel+Inspector.swift`'s `maskedVisitor(_:)`, which is `private` to that file and
    /// therefore unreachable across files (the same `private`-doesn't-cross-files rule). `static`
    /// because it needs no instance state, keeping it trivially testable.
    private static func maskedVisitorID(_ visitorId: String) -> String {
        guard !visitorId.isEmpty else { return "<none>" }
        return "\(visitorId.prefix(6))…"
    }
}

/// The Config info panel's input bundle (masked SDK key, environment, target keys, tracking flag),
/// assembled by ``DemoViewModel/configPanelData``. A plain value type so the panel renders from one
/// testable struct; defined here because Story 7.6 owns the Config surface.
struct ConfigPanelData: Equatable {
    /// The display-safe SDK key (already routed through ``toLoggable(_:)``).
    let maskedKey: String
    /// The environment label ("default" when none is configured).
    let environment: String
    /// The experience key the Experiences screen targets.
    let experienceKey: String
    /// The feature key the Features screen targets.
    let featureKey: String
    /// Whether event/network tracking is enabled.
    let trackingEnabled: Bool
}

// ConvertContext.swift
// Visitor-scoped experimentation context (Epic 2 / Story 2 — stub).
// Real bucketing, feature resolution, and tracking arrive in Epics 3–4.

import Foundation

/// A visitor-scoped handle for running experiences/features and tracking conversions.
///
/// Story 2.2 ships the public surface as a stub: every decisioning method returns its DEGRADED
/// value and never throws (AOD-6 — the public API never surfaces a thrown error to callers), so an
/// integration compiles and runs against the final signatures before the Epic 3–4 engines land.
/// Story 3.1 makes the visitor identity REAL: the context carries the resolved ``visitorId``, the
/// coerced ``attributes``, and the SDK's one canonical ``DecisionStore`` — while the decisioning
/// stubs stay degraded until Epics 3–4 wire bucketing/feature resolution.
///
/// `Sendable` with NO `@unchecked` and no suppression: every stored property is an immutable `let`
/// of a `Sendable` type — the owning ``ConvertSDK`` (`Sendable`, held acyclically since the SDK keeps
/// no back-reference), the `String` ``visitorId``, the `[String: ConvertValue]` attribute storage
/// (``ConvertValue`` is `Sendable`, so the dictionary is), and the ``DecisionStore`` `actor`
/// (`Sendable`). The public ``attributes`` is a COMPUTED `[String: Any]` (no stored `Any`), so it
/// does not weaken the conformance.
public final class ConvertContext: Sendable {
    /// The SDK that created this context. Strong and immutable: acyclic (the SDK holds no
    /// back-reference) and `Sendable` (``ConvertSDK`` is `Sendable`).
    private let sdk: ConvertSDK

    /// The effective visitor identifier resolved at creation by ``VisitorContextManager`` — an
    /// explicit caller-supplied ID verbatim, else the persisted Keychain/mirror value, else a freshly
    /// generated + persisted `UUID().uuidString`. Immutable for the context's lifetime (bucketing
    /// parity depends on a stable per-context identity).
    public let visitorId: String

    /// The visitor attributes coerced into the closed ``ConvertValue`` scalar set. `Sendable` storage
    /// (``ConvertValue`` is `Sendable`); the public ``attributes`` reconstructs the `[String: Any]`
    /// view from it. Stored as `ConvertValue` rather than raw `Any` so the class stays `Sendable`
    /// with no suppression.
    private let attributesStorage: [String: ConvertValue]

    /// The SDK's ONE canonical ``DecisionStore``, injected so every context from the same SDK shares
    /// a single store (sticky variations / goal-dedup / segments converge on one instance). `internal`
    /// — the decisioning engines (Stories 3.4 / 4.2) reach it from within the module; it is not part of
    /// the public surface.
    internal let decisionStore: DecisionStore

    /// The visitor attributes as a loosely-typed `[String: Any]` map, reconstructed on each access
    /// from the internal ``ConvertValue`` storage via ``ConvertValue/anyValue`` — so a value supplied
    /// as `["age": 30]` reads back as `attributes["age"] as? Int == 30`. A COMPUTED property (no stored
    /// `Any`), which is why it does not weaken the class's `Sendable` conformance. Values that could
    /// not be coerced at creation (nested dictionaries/arrays/etc.) are absent here — they were dropped
    /// because they are not segment-matchable scalars.
    public var attributes: [String: Any] {
        attributesStorage.mapValues { $0.anyValue }
    }

    /// Binds the context to its creating SDK and its resolved visitor identity. Created only via
    /// ``ConvertSDK/createContext(visitorId:attributes:)``, which resolves `visitorId` through
    /// ``VisitorContextManager`` and passes the SDK's canonical `decisionStore`.
    ///
    /// `attributes` arrive ALREADY coerced into the closed ``ConvertValue`` set — the
    /// `[String: Any]` → `[String: ConvertValue]` coercion (and the per-key DEBUG log for any
    /// unsupported value that was dropped) happens UPSTREAM in
    /// ``ConvertSDK/createContext(visitorId:attributes:)``, which holds the SDK's logger. Keeping the
    /// coercion there leaves this context free of a logger dependency; the public
    /// `createContext(attributes:)` parameter stays `[String: Any]?` and the ``attributes`` getter
    /// stays `[String: Any]`, so the loosely-typed surface is unchanged for consumers.
    /// - Parameters:
    ///   - sdk: The creating SDK (held acyclically).
    ///   - visitorId: The already-resolved effective visitor identifier.
    ///   - attributes: The caller-supplied attributes, already coerced to ``ConvertValue`` (unsupported
    ///     values were dropped, and logged at DEBUG, by ``ConvertSDK/createContext(visitorId:attributes:)``).
    ///   - decisionStore: The SDK's canonical decision store, shared across every context it creates.
    internal init(
        sdk: ConvertSDK,
        visitorId: String,
        attributes: [String: ConvertValue],
        decisionStore: DecisionStore
    ) {
        self.sdk = sdk
        self.visitorId = visitorId
        self.decisionStore = decisionStore
        self.attributesStorage = attributes
    }

    /// Whether event delivery is enabled for this context's SDK (FR6 static `network.tracking`).
    ///
    /// The real gate a future `eventSink.enqueue` call site checks: when `false`, bucketing/decisioning
    /// still runs and returns decisions, but produced tracking events are NOT enqueued (suppression is a
    /// CALLER concern here, not an `EventQueue` concern). The enqueue sites arrive in Epics 3-4; this hook
    /// is scaffolded now so the toggle is already in place when they do (Story 2.4 Task 4 / AC8).
    internal func trackingEnabled() -> Bool {
        sdk.networkTrackingEnabled
    }

    /// Runs one experience and returns the bucketed ``Variation``, or `nil` when none applies.
    /// Stub: returns `nil` (degraded) until Epic 3 wires bucketing.
    public func runExperience(_ key: String, enableTracking: Bool = true) async -> Variation? {
        // [WARN] ConvertContext.runExperience: not yet implemented (Epic 3).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return nil }
        //   — wired when Epics 3-4 add eventSink.enqueue
        nil
    }

    /// Runs every applicable experience and returns the bucketed ``Variation``s. Stub: returns
    /// `[]` (degraded) until Epic 3 wires bucketing.
    public func runExperiences(enableTracking: Bool = true) async -> [Variation] {
        // [WARN] ConvertContext.runExperiences: not yet implemented (Epic 3).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return [] }
        //   — wired when Epics 3-4 add eventSink.enqueue
        []
    }

    /// Resolves one feature flag and returns its ``BucketedFeature``. Non-optional by
    /// contract, so the stub returns a DEGRADED feature — disabled, empty variables — rather
    /// than throwing (AOD-6). Real resolution arrives in Epic 4.
    public func runFeature(_ key: String, enableTracking: Bool = true) async -> BucketedFeature {
        // [WARN] ConvertContext.runFeature: not yet implemented (Epic 4).
        BucketedFeature(id: "", key: key, status: .disabled, variables: [:])
    }

    /// Resolves every feature flag and returns its ``BucketedFeature``s. Stub: returns `[]`
    /// (degraded) until Epic 4 wires feature resolution.
    public func runFeatures(enableTracking: Bool = true) async -> [BucketedFeature] {
        // [WARN] ConvertContext.runFeatures: not yet implemented (Epic 4).
        []
    }

    /// Tracks a conversion for `goalKey` with optional ``GoalData``. Stub: no-op until Epic 4
    /// wires the tracking pipeline.
    public func trackConversion(_ goalKey: String, goalData: GoalData? = nil) async {
        // [WARN] ConvertContext.trackConversion: not yet implemented (Epic 4).
        // tracking toggle guard (FR6): guard trackingEnabled() else { return }
        //   — wired when Epics 3-4 add eventSink.enqueue
    }

    /// Sets the default visitor ``Segments``. Stub: no-op until Epic 4 wires segmentation.
    public func setDefaultSegments(_ segments: Segments) {
        // [WARN] ConvertContext.setDefaultSegments: not yet implemented (Epic 4).
    }

    /// Sets the custom segment identifiers for the visitor. Stub: no-op until Epic 4 wires
    /// custom segmentation.
    public func setCustomSegments(_ segmentIds: [String]) {
        // [WARN] ConvertContext.setCustomSegments: not yet implemented (Epic 4).
    }
}

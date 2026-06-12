// ConvertContext.swift
// Visitor-scoped experimentation context (Epic 2 / Story 2 — stub).
// Real bucketing, feature resolution, and tracking arrive in Epics 3–4.
//
// `file_length` is disabled file-wide (a single named rule — NOT a blanket `disable all`): this is the
// SDK's public-surface hub, and its DocC-heavy house style (each public method carries the full FR/AR/AC
// rationale) pushed it past the 400-line default once Story 4.3 added the conversion dedup gate, the
// two-event emission, and the `forceMultipleTransactions` override to `trackConversion`. Trimming the
// mandated rationale to chase the line count would trade documentation rigor for a cosmetic number; the
// named-rule suppression keeps every other rule — and the 400-line gate on every OTHER file — enforced.
// swiftlint:disable file_length

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

    /// The SDK's single, fully-wired ``ExperienceManager`` that ``runExperience(_:enableTracking:)``
    /// delegates to (Story 3.4). Injected from ``ConvertSDK`` (built once over the SDK's canonical
    /// ``decisionStore`` and shared event bus), so every context buckets through the SAME manager —
    /// sticky decisions and `.bucketing` fires converge on the shared instances. ``ExperienceManager``
    /// is a stateless `Sendable` `struct`, so storing it as a `let` keeps this class an all-`let`
    /// `Sendable final class` with no suppression.
    private let experienceManager: ExperienceManager

    /// The SDK's single, fully-wired ``FeatureManager`` that ``runFeature(_:)`` and
    /// ``runFeatures()`` delegate to (Story 4.1). Injected from ``ConvertSDK`` (built
    /// once over the same ``ExperienceManager`` this context delegates experiences to), so feature
    /// evaluation buckets through the SAME underlying manager — sticky decisions and `.bucketing` fires
    /// converge on the shared instances. ``FeatureManager`` is a stateless `Sendable` `struct`, so
    /// storing it as a `let` keeps this class an all-`let` `Sendable final class` with no suppression.
    private let featureManager: FeatureManager

    /// The SDK's ``EventSink`` this context enqueues the CONVERSION entry through in
    /// ``trackConversion(_:goalData:)`` (Story 4.2, AR14 — events are produced at the ``EventSink``
    /// port, never at a concrete `EventQueue`). Injected from ``ConvertSDK`` (its `eventSink`, default
    /// ``NoopEventSink`` in production). The ``EventSink`` port refines `Sendable`, so this `let` keeps
    /// the class an all-`let` `Sendable final class` with no suppression.
    private let eventSink: any EventSink

    /// The SDK's shared ``EventBus`` this context fires ``SystemEvent/conversion`` on in
    /// ``trackConversion(_:goalData:)`` (Story 4.2, AC9), so a `sdk.on(.conversion)` subscriber is
    /// notified. The SAME bus the owning ``ConvertSDK`` exposes through `on`/`off`, so a conversion
    /// fired here reaches the SDK's subscribers. ``EventBus`` is an `actor` (`Sendable`), so this `let`
    /// keeps the class an all-`let` `Sendable final class` with no suppression.
    private let eventBus: EventBus

    /// The SDK's ``Logger`` this context emits its ``trackConversion(_:goalData:)`` drop-path WARNs to
    /// (AOD-6 — the SDK-not-ready and goal-not-found degradations log + drop, never throw). Injected
    /// from ``ConvertSDK`` (its `logger`, default ``NoopLogger`` in production). The ``Logger`` port
    /// refines `Sendable`, so this `let` keeps the class an all-`let` `Sendable final class` with no
    /// suppression.
    private let logger: any Logger

    /// The SDK's segment assignment engine, constructed over the SAME canonical ``decisionStore`` this
    /// context is injected with (Story 4.4). ``setDefaultSegments(_:)`` / ``setCustomSegments(_:)``
    /// delegate to it, and ``runExperience(_:enableTracking:)`` reads the persisted result back from that
    /// shared store to overlay onto the audience-rule attribute map (AC11). ``SegmentsManager`` is a
    /// stateless `Sendable` `struct` (it owns no mutable state — the `actor` store does), so storing it as
    /// a `let` keeps this class an all-`let` `Sendable final class` with no suppression.
    private let segmentsManager: SegmentsManager

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
    ///   - experienceManager: The SDK's single wired ``ExperienceManager`` this context delegates
    ///     `runExperience` to (Story 3.4), shared across every context the SDK creates.
    ///   - featureManager: The SDK's single wired ``FeatureManager`` this context delegates
    ///     `runFeature` / `runFeatures` to (Story 4.1), shared across every context the SDK creates.
    ///   - eventSink: The SDK's ``EventSink`` the CONVERSION seam enqueues through in
    ///     ``trackConversion(_:goalData:)`` (Story 4.2 / AR14); default ``NoopEventSink`` in production.
    ///   - eventBus: The SDK's shared ``EventBus`` ``trackConversion(_:goalData:)`` fires
    ///     ``SystemEvent/conversion`` on (Story 4.2 / AC9), so `sdk.on(.conversion)` subscribers fire.
    ///   - logger: The SDK's ``Logger`` ``trackConversion(_:goalData:)`` emits its drop-path WARNs to
    ///     (Story 4.2 / AOD-6); default ``NoopLogger`` in production.
    internal init(
        sdk: ConvertSDK,
        visitorId: String,
        attributes: [String: ConvertValue],
        decisionStore: DecisionStore,
        experienceManager: ExperienceManager,
        featureManager: FeatureManager,
        eventSink: any EventSink,
        eventBus: EventBus,
        logger: any Logger
    ) {
        self.sdk = sdk
        self.visitorId = visitorId
        self.decisionStore = decisionStore
        self.attributesStorage = attributes
        self.experienceManager = experienceManager
        self.featureManager = featureManager
        self.eventSink = eventSink
        self.eventBus = eventBus
        self.logger = logger
        // Built over the injected canonical store (not a separate parameter — callers do not pass it), so
        // every context from the same SDK records segments into the ONE store the decisioning path reads.
        self.segmentsManager = SegmentsManager(decisionStore: decisionStore, logger: logger)
    }

    /// Whether event delivery is enabled for this context's SDK (FR6 static `network.tracking`).
    ///
    /// The caller-side gate the enqueue sites honour: when `false`, bucketing/decisioning still runs and
    /// returns decisions, but produced tracking events are NOT enqueued (suppression is a CALLER concern
    /// here, not an `EventQueue` concern). Story 2.4 scaffolded this hook; Story 5.4 made it load-bearing —
    /// ``trackConversion(_:goalData:forceMultipleTransactions:)`` reads ``ConvertSDK/networkTrackingEnabled``
    /// directly to gate its two conversion enqueues, and ``runExperience(_:enableTracking:)`` /
    /// ``runExperiences(enableTracking:)`` combine it with the per-call flag threaded into the bucketing
    /// path. This accessor remains the public-intent expression of that same flag.
    internal func trackingEnabled() -> Bool {
        sdk.networkTrackingEnabled
    }

    /// Runs one experience and returns the bucketed ``Variation``, or `nil` when none applies.
    ///
    /// Reads the SDK's current config snapshot from its ``ConfigStore``; a `nil` snapshot (pre-ready,
    /// or a degraded load that resolved with no config) short-circuits to `nil` WITHOUT touching the
    /// manager (AC10 / AOD-6 — the degraded path returns `nil`, never throws). Otherwise delegates to
    /// the injected ``ExperienceManager``, which honours sticky assignment, the audience / location
    /// gates, and `enableTracking`, returning its ``Variation?`` verbatim. Never throws.
    ///
    /// `accountId` / `projectId` come from the snapshot (`account_id` / `project.id`), defaulting to
    /// `""` when absent — they form the sticky store key `"<accountId>-<projectId>-<visitorId>"`, so an
    /// absent id yields a stable (if empty-segmented) key rather than a crash. `locationProperties` is
    /// empty on native: the JS SDK's location model is caller-supplied browser context with no native
    /// equivalent (the Foundation-only core has no CoreLocation dependency), so the location gate is
    /// driven only by an explicitly-empty map here (an experience with no `locations` is unrestricted
    /// and passes); native location targeting is out of scope for this story.
    /// - Parameters:
    ///   - key: The experience `key` to look up and bucket.
    ///   - enableTracking: When `false`, the manager suppresses the bucketing enqueue (the variation is
    ///     still selected, persisted, and the `.bucketing` event fired); defaults to `true`.
    /// - Returns: The bucketed ``Variation``, or `nil` on a missing snapshot / gate failure / miss.
    public func runExperience(_ key: String, enableTracking: Bool = true) async -> Variation? {
        guard let config = await sdk.configStore.getSnapshot() else {
            // Pre-ready / degraded: a nil snapshot resolves to a nil variation without reaching the
            // manager (AC10, no throw).
            return nil
        }
        // AC11: overlay the visitor's persisted segments onto the explicit attribute map so an audience
        // rule can match on a `setDefaultSegments` value (e.g. country). Read under the SAME store key the
        // manager rebuilds internally; explicit createContext attributes still win on collision.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        // Thread the COMBINED gate (FR6 global `network.tracking` AND the per-call `enableTracking`) into
        // the manager: the variation is still selected/persisted/fired, but `BucketingManager` skips the
        // bucketing enqueue when EITHER flag is false — so a globally-disabled SDK enqueues nothing at the
        // sink even though decisioning is unchanged (Story 5.4 / AC1, AC3). The public `enableTracking`
        // parameter and its default are unchanged; only the value threaded down is combined.
        return await experienceManager.selectVariation(
            forKey: key,
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: [:],
            enableTracking: sdk.networkTrackingEnabled && enableTracking
        )
    }

    /// The visitor attributes as the `[String: String]` map the rule / segment engine compares against.
    ///
    /// ``RuleManager`` / `Comparisons` evaluate audience and location rules against STRING values
    /// (the wire/comparison form), so each ``ConvertValue`` scalar is stringified to its canonical
    /// textual form: a string stays itself, an int / double / bool render via their `String(_:)`
    /// initialisers (e.g. `.int(30)` → `"30"`, `.bool(true)` → `"true"`). A private read-only view over
    /// the immutable ``attributesStorage`` — it allocates a fresh dictionary per call but is invoked
    /// once per `runExperience`, so there is no retained mutable state and the class stays `Sendable`.
    private func stringAttributes() -> [String: String] {
        attributesStorage.mapValues { value in
            switch value {
            case .string(let string): return string
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            }
        }
    }

    /// The sticky store key `"<accountId>-<projectId>-<visitorId>"` for the given config snapshot.
    /// `accountId`/`projectId` default to `""` when absent (a stable, if empty-segmented, key). One owner
    /// of the key shape that ``trackConversion(_:goalData:forceMultipleTransactions:)``, the new
    /// segmentation methods, and ``runExperience(_:enableTracking:)``'s segment overlay all share — and the
    /// same shape ``ExperienceManager`` rebuilds internally, so the segments overlay reads under the SAME
    /// key the manager buckets against.
    private func storeKey(for config: ProjectConfig) -> String {
        "\(config.accountId ?? "")-\(config.project?.id ?? "")-\(visitorId)"
    }

    /// Overlays the visitor's non-nil string segment fields onto the explicit attribute map so audience
    /// rules can match on `country`/`visitorType`/etc. Explicit attributes WIN on key collision (the
    /// caller's createContext attribute is more specific than a stored segment). `customSegments` is an
    /// array, not a scalar attribute, so it is NOT overlaid. [Source: AC11]
    private func mergedAttributes(_ attributes: [String: String], with segments: Segments) -> [String: String] {
        var merged = attributes
        let segmentPairs: [(String, String?)] = [
            ("country", segments.country), ("browser", segments.browser), ("devices", segments.devices),
            ("source", segments.source), ("campaign", segments.campaign), ("visitorType", segments.visitorType)
        ]
        for (key, value) in segmentPairs where merged[key] == nil {
            if let value { merged[key] = value }
        }
        return merged
    }

    /// Runs every configured experience for this visitor and returns the bucketed ``Variation`` for
    /// each eligible one, in config order. Reads the SDK's current config snapshot from its
    /// ``ConfigStore``; a `nil` snapshot (pre-ready / degraded) returns `[]` WITHOUT touching the
    /// manager (AOD-6 — degraded returns empty, never throws). Otherwise delegates to the injected
    /// ``ExperienceManager/selectVariations(...)`` bulk path, which evaluates every experience through
    /// the full single-experience pipeline (sticky /
    /// audience / location / bucket / persist / event) and returns only the eligible variations. A thin
    /// bulk twin of ``runExperience(_:enableTracking:)``.
    ///
    /// `enableTracking` is combined with the SDK's global `network.tracking` flag and the result threaded
    /// to the bulk path, exactly as ``runExperience(_:enableTracking:)`` threads it (run-all mirrors
    /// run-single, not diverge): the per-experience bucketing enqueue is suppressed when EITHER flag is
    /// false (Story 5.4 / FR6), while each variation is still selected, persisted, and fired. `accountId` /
    /// `projectId` come from the snapshot (defaulting to `""` when absent), and `locationProperties` is
    /// empty on native — identical to the single-experience path. Never throws.
    /// - Parameter enableTracking: When `false`, variations are still computed but the per-experience
    ///   bucketing enqueue is suppressed (passed through to the bulk path); defaults to `true`.
    /// - Returns: The bucketed ``Variation`` for each eligible experience in config order, or `[]`
    ///   on a missing snapshot.
    public func runExperiences(enableTracking: Bool = true) async -> [Variation] {
        guard let config = await sdk.configStore.getSnapshot() else {
            return []
        }
        // AC11: same segment overlay as the single-experience path (run-all mirrors run-single, not
        // diverge) — each experience's audience gate sees the visitor's persisted segments.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        // Thread the COMBINED gate (global `network.tracking` AND per-call `enableTracking`) into the bulk
        // path, exactly as the single-experience path does (run-all mirrors run-single, not diverge): each
        // per-experience bucketing enqueue is suppressed when EITHER flag is false, while every variation is
        // still selected/persisted/fired (Story 5.4 / AC1, AC3).
        return await experienceManager.selectVariations(
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: [:],
            enableTracking: sdk.networkTrackingEnabled && enableTracking
        )
    }

    /// Resolves one feature flag and returns its ``Feature`` — non-optional by contract, so
    /// the degraded answer is a DISABLED feature (never a throw, AOD-6).
    ///
    /// Reads the SDK's current config snapshot from its ``ConfigStore``; a `nil` snapshot (pre-ready,
    /// or a degraded load that resolved with no config) short-circuits to ``Feature/disabled(key:)``
    /// WITHOUT touching the manager — the feature twin of ``runExperience(_:enableTracking:)`` returning
    /// `nil` on an absent snapshot. Otherwise delegates to the injected ``FeatureManager``, which resolves
    /// the feature by delegating bucketing to ``ExperienceManager`` (sticky / audience / location / traffic),
    /// enabling it when the visitor buckets into a carrying experience and surfacing its typed variables.
    /// Never throws.
    ///
    /// `accountId` / `projectId` come from the snapshot (defaulting to `""` when absent) and
    /// `locationProperties` is empty on native — identical to ``runExperience(_:enableTracking:)``.
    /// Unlike the experience API, this method takes NO `enableTracking` parameter (Android parity, F-171):
    /// the feature path is not per-call tracking-gated; feature evaluation delegates to ``FeatureManager``,
    /// which lets the underlying experience bucketing track per its own contract.
    ///
    /// SCOPE ASYMMETRY (Story 5.4, deliberate): unlike ``runExperience(_:enableTracking:)`` /
    /// ``runExperiences(enableTracking:)`` (which combine the global `network.tracking` flag into the
    /// bucketing path) and ``trackConversion(_:goalData:forceMultipleTransactions:)`` (which gates its
    /// enqueues on it), the feature path is NOT caller-gated by `network.tracking` in this story — Story
    /// 5.4's AC1 names only `runExperience`/`runExperiences`/`trackConversion`. A feature whose carrying
    /// experience buckets here still produces a bucketing enqueue at the ``EventSink``; when
    /// `network.tracking` is off, the PRODUCTION ``EventQueue`` drops that entry at its own static gate
    /// (`trackingEnabled`), so no event reaches the network — the suppression happens one seam later than
    /// on the experience/conversion paths, not at this caller.
    /// - Parameter key: The feature `key` to look up and resolve.
    /// - Returns: The resolved ``Feature`` — `.enabled` with typed variables, or `.disabled` on a
    ///   missing snapshot / miss.
    public func runFeature(_ key: String) async -> Feature {
        guard let config = await sdk.configStore.getSnapshot() else {
            // Pre-ready / degraded: a nil snapshot resolves to a disabled feature without reaching the
            // manager (AOD-6, no throw).
            return Feature.disabled(key: key)
        }
        // AC11 (JS parity, bd-0ca): overlay the visitor's persisted segments onto the explicit attribute map
        // so the carrying experience's audience gate can match on a `setDefaultSegments` value, exactly as
        // runExperience does — JS context.ts calls getVisitorProperties identically on the feature path.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        return await featureManager.evaluateFeature(
            key: key,
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: [:]
        )
    }

    /// Resolves every feature in the config and returns its ``Feature``, in config order.
    ///
    /// Reads the SDK's current config snapshot from its ``ConfigStore``; a `nil` snapshot (pre-ready /
    /// degraded) returns `[]` WITHOUT touching the manager (AOD-6 — degraded returns empty, never throws),
    /// the feature twin of ``runExperiences(enableTracking:)``. Otherwise delegates to the injected
    /// ``FeatureManager/evaluateAllFeatures(in:visitorId:accountId:projectId:attributes:locationProperties:)``,
    /// which enumerates `config.features` and resolves each through the single-feature path. `accountId` /
    /// `projectId` come from the snapshot (defaulting to `""` when absent) and `locationProperties` is
    /// empty on native — identical to the single-feature path. Never throws.
    ///
    /// As with ``runFeature(_:)``, this method takes NO `enableTracking` parameter (Android parity, F-171):
    /// the feature path is not per-call tracking-gated.
    /// - Returns: One ``Feature`` per `config.features` entry, in config order; `[]` on a missing
    ///   snapshot.
    public func runFeatures() async -> [Feature] {
        guard let config = await sdk.configStore.getSnapshot() else {
            return []
        }
        // AC11 (JS parity, bd-0ca): same segment overlay as the single-feature path (run-all mirrors
        // run-single, not diverge) — each feature's carrying-experience audience gate sees the visitor's
        // persisted segments.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        return await featureManager.evaluateAllFeatures(
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: [:]
        )
    }

    /// Tracks a conversion for `goalKey`, optionally carrying per-goal ``GoalData`` metrics, with a
    /// per-visitor dedup gate and an opt-in multiple-transactions override.
    ///
    /// `async` but NEVER throws (AOD-6). Two degraded inputs each WARN and DROP (enqueuing nothing),
    /// returning BEFORE the dedup gate: no usable config snapshot (pre-ready / degraded load) → WARN
    /// "SDK not ready…" before any goal lookup (the twin of ``runExperience(_:enableTracking:)``
    /// short-circuiting to `nil`); and `goalKey` absent (``ProjectConfig/goal(forKey:)`` miss) → WARN
    /// "…not found in config, dropping." The WARN `message` is ONLY the descriptive tail — the adapter
    /// composes the `[WARN] ConvertContext.trackConversion: …` prefix from `type`/`method` (UX-DR19).
    ///
    /// Past the guards it resolves `goalId` (the goal's wire `id`; `?? ""` since it is `String?`) and
    /// `bucketingData` (the visitor's sticky ``DecisionStore/bucketingDecisions(forStoreKey:)`` under the
    /// `"<accountId>-<projectId>-<visitorId>"` key, or `nil` when empty — FR27 collapses `{}` to omit the
    /// wire key, the anti-Android-regression guard), then applies a DEDUP gate via
    /// ``DecisionStore/markGoalTriggeredIfNeeded(goalId:forVisitorKey:)`` (one atomic check-and-mark;
    /// `true` ⇒ FIRST trigger) and emits up to TWO independent ``TrackingEventEntry/conversion(_:)`` events
    /// through the injected ``EventSink`` port — NOT a concrete `EventQueue` (AR14; real queue lands Epic 5
    /// as a one-site swap of ``NoopEventSink``):
    ///   * CONVERSION event (`goalData == nil`) — enqueued ONLY on the first trigger, which also FIRES
    ///     ``SystemEvent/conversion`` with a ``ConversionPayload`` (AC9) once (`.conversion` already exists;
    ///     no new case). A repeat trigger emits neither — just a WARN, then FALLS THROUGH to the txn gate.
    ///   * TRANSACTION event (`goalData == data.toEntries()`, the wire `{key, value}` array) — enqueued when
    ///     `goalData` is present AND (first trigger OR `forceMultipleTransactions`), recording a deliberate
    ///     repeat purchase as a second transaction without re-emitting the conversion.
    ///
    /// The global `network.tracking` gate (FR6) IS applied here (Story 5.4): when off, neither the
    /// conversion event nor the transaction event is enqueued at the ``EventSink`` (one DEBUG line records
    /// the suppression), while the dedup mark still persists and the ``SystemEvent/conversion`` bus signal
    /// still fires on first trigger (JS parity — only delivery is gated). The conversion path has no
    /// per-call `enableTracking` (FR23), so it gates on the global flag alone.
    /// - Parameters:
    ///   - goalKey: The goal `key` to look up in the config and convert on.
    ///   - goalData: Optional per-goal metrics (e.g. revenue `amount`, `transactionId`); drives the
    ///     separate TRANSACTION event and is absent from the conversion event.
    ///   - forceMultipleTransactions: When `true`, the TRANSACTION event is emitted for `goalData` even on
    ///     an ALREADY-triggered goal (the conversion + bus signal stay suppressed). Defaults to `false`
    ///     (plain repeat call is a WARN-only no-op); has no effect without `goalData`.
    ///
    /// The body exceeds the 50-line `function_body_length` default by ONE line because the Story 5.4
    /// `network.tracking` gate added the suppression-log block + the two enqueue guards on top of the
    /// already-dense two-degrade-guard / dedup / conversion-gate / transaction-gate pipeline (each carrying
    /// its mandated FR/AR/AC rationale inline). Splitting the gate out would scatter the dedup ↔ bus-fire ↔
    /// enqueue ordering that the inline comments document as load-bearing. Targeted disable on this one
    /// method (precedent: `ConvertSDK.init` / `ExperienceManager.selectVariation` in this codebase) rather
    /// than raising the project-wide threshold; the directive is on the `func` line so the `///` doc stays
    /// flush against the declaration (avoids `orphaned_doc_comment`).
    public func trackConversion( // swiftlint:disable:this function_body_length
        _ goalKey: String,
        goalData: GoalData? = nil,
        forceMultipleTransactions: Bool = false
    ) async {
        guard let config = await sdk.configStore.getSnapshot() else {
            logger.log(
                level: .warn,
                type: "ConvertContext",
                method: "trackConversion",
                message: "SDK not ready, dropping conversion for goal '\(goalKey)'."
            )
            return
        }
        guard let goal = config.goal(forKey: goalKey) else {
            logger.log(
                level: .warn,
                type: "ConvertContext",
                method: "trackConversion",
                message: "goal '\(goalKey)' not found in config, dropping."
            )
            return
        }
        // Sticky store key "<accountId>-<projectId>-<visitorId>" (the runExperience key shape); goalId
        // resolved ONCE so the enqueued event and the `.conversion` bus payload share it.
        let storeKey = "\(config.accountId ?? "")-\(config.project?.id ?? "")-\(visitorId)"
        let decisions = await decisionStore.bucketingDecisions(forStoreKey: storeKey)
        let bucketingData = decisions.isEmpty ? nil : decisions
        let goalId = goal.id ?? ""
        // Atomic check-and-mark: `true` ⇒ first trigger (proceed), `false` ⇒ already triggered (suppress
        // the conversion, but NOT a forced txn). Written BEFORE the network gate below, so the dedup state
        // persists even with tracking off (Story 5.4 / AC5).
        let firstTrigger = await decisionStore.markGoalTriggeredIfNeeded(goalId: goalId, forVisitorKey: storeKey)
        // Global `network.tracking` gate (FR6): a non-suspending read of the SDK flag. When OFF, NO entry
        // enters the `EventSink` on EITHER gate below — but the dedup mark above STILL persists and the
        // local `.conversion` bus signal STILL fires on first trigger (JS parity: `context.ts` fires
        // `SystemEvents.CONVERSION` on trigger independent of the network gate — only delivery to the queue
        // is suppressed). Exactly ONE DEBUG line records the suppression for this call (Story 5.4 / AC6);
        // the message is a fixed descriptive tail carrying NO SDK key / secret (NFR6).
        let networkTrackingOn = sdk.networkTrackingEnabled
        if !networkTrackingOn {
            logger.log(
                level: .debug,
                type: "ConvertContext",
                method: "trackConversion",
                message: "event suppressed — networkTracking=false"
            )
        }
        // CONVERSION gate — first trigger enqueues the conversion event (only when tracking is on) and
        // fires `.conversion` once REGARDLESS of the network gate. A repeat trigger WARNs and (crucially)
        // does NOT `return`: control falls through to the txn gate.
        if firstTrigger {
            if networkTrackingOn {
                let event = ConversionEventData(goalId: goalId, goalData: nil, bucketingData: bucketingData)
                await eventSink.enqueue(.conversion(event), for: visitorId, segments: nil)
            }
            let payload = ConversionPayload(goalId: goalId, visitorId: visitorId)
            await eventBus.fire(.conversion, payload: .conversion(payload))
        } else {
            logger.log(
                level: .warn,
                type: "ConvertContext",
                method: "trackConversion",
                message: "goal '\(goalId)' already tracked for visitor, skipping."
            )
        }
        // TRANSACTION gate (independent) — emits the goalData event on the first trigger OR when
        // `forceMultipleTransactions` overrides dedup for a deliberate repeat purchase, but only when
        // network tracking is on (the suppression was already logged once above).
        if networkTrackingOn, let data = goalData, firstTrigger || forceMultipleTransactions {
            let event = ConversionEventData(goalId: goalId, goalData: data.toEntries(), bucketingData: bucketingData)
            await eventSink.enqueue(.conversion(event), for: visitorId, segments: nil)
        }
    }

    /// Sets default visitor segments (merge semantics) and fires ``SystemEvent/segments`` once.
    ///
    /// `async` but NEVER throws (AOD-6). Delegates the merge to ``SegmentsManager`` (each of the six
    /// recognised string keys overlays the visitor's existing segments; unknown keys WARN and are
    /// ignored), reads the resolved ``Segments`` back from the shared ``decisionStore``, and fires
    /// ``SystemEvent/segments`` ONCE with a ``SegmentsPayload`` carrying them (AC12). A `nil` config
    /// snapshot (pre-ready / degraded) means there is no account/project to form the sticky store key —
    /// it WARNs and returns WITHOUT firing, the same degrade ``trackConversion(_:goalData:forceMultipleTransactions:)``
    /// applies on a not-ready SDK. The WARN `message` is ONLY the descriptive tail; the adapter composes
    /// the `[WARN] ConvertContext.setDefaultSegments: …` prefix from `type`/`method` (UX-DR19).
    /// - Parameter segments: The wire-keyed string segment fields to merge (`country`, `browser`,
    ///   `devices`, `source`, `campaign`, `visitorType`); unrecognised keys are ignored with a WARN.
    /// [Source: AC1, AC12]
    public func setDefaultSegments(_ segments: [String: String]) async {
        guard let config = await sdk.configStore.getSnapshot() else {
            logger.log(
                level: .warn,
                type: "ConvertContext",
                method: "setDefaultSegments",
                message: "SDK not ready, dropping segments update."
            )
            return
        }
        let key = storeKey(for: config)
        await segmentsManager.setDefaultSegments(segments, forVisitorKey: key)
        let updated = await segmentsManager.currentSegments(forVisitorKey: key)
        await eventBus.fire(.segments, payload: .segments(SegmentsPayload(visitorId: visitorId, segments: updated)))
    }

    /// Appends custom segment identifiers for the visitor and fires ``SystemEvent/segments`` once.
    ///
    /// `async` but NEVER throws (AOD-6). Delegates the append to ``SegmentsManager`` (the ids are added to
    /// the visitor's existing `customSegments`; backend owns dedup, matching JS), reads the resolved
    /// ``Segments`` back from the shared ``decisionStore``, and fires ``SystemEvent/segments`` ONCE with a
    /// ``SegmentsPayload`` (AC12). A `nil` config snapshot (pre-ready / degraded) WARNs and returns WITHOUT
    /// firing — the same not-ready degrade as ``setDefaultSegments(_:)``.
    /// - Parameter segmentIds: The custom segment identifiers to append to the visitor's `customSegments`.
    /// [Source: AC2, AC12]
    public func setCustomSegments(_ segmentIds: [String]) async {
        guard let config = await sdk.configStore.getSnapshot() else {
            logger.log(
                level: .warn,
                type: "ConvertContext",
                method: "setCustomSegments",
                message: "SDK not ready, dropping custom segments update."
            )
            return
        }
        let key = storeKey(for: config)
        await segmentsManager.setCustomSegments(segmentIds, forVisitorKey: key)
        let updated = await segmentsManager.currentSegments(forVisitorKey: key)
        await eventBus.fire(.segments, payload: .segments(SegmentsPayload(visitorId: visitorId, segments: updated)))
    }
}

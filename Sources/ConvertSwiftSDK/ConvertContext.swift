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

import ConvertSwiftSDKCore
import Foundation

/// A visitor-scoped handle for running experiences/features and tracking conversions.
///
/// ```swift
/// // given a ready `sdk`
/// let context = sdk.createContext()
/// if let variation = await context.runExperience("pricing-test") {
///     print("Variation \(variation.key)")
/// }
/// ```
///
/// Story 2.2 ships the public surface as a stub: every decisioning method returns its DEGRADED
/// value and never throws (AOD-6 — the public API never surfaces a thrown error to callers), so an
/// integration compiles and runs against the final signatures before the Epic 3–4 engines land.
/// Story 3.1 makes the visitor identity REAL: the context carries the resolved ``visitorId``, the
/// coerced ``attributes``, and the SDK's one canonical ``DecisionStore`` — while the decisioning
/// stubs stay degraded until Epics 3–4 wire bucketing/feature resolution.
///
/// `Sendable` with NO `@unchecked` and no suppression: every stored property is an immutable `let`
/// of a `Sendable` type — the owning ``ConvertSwiftSDK`` (`Sendable`, held acyclically since the SDK keeps
/// no back-reference), the `String` ``visitorId``, the `[String: ConvertValue]` attribute storage
/// (``ConvertValue`` is `Sendable`, so the dictionary is), and the ``DecisionStore`` `actor`
/// (`Sendable`). The public ``attributes`` is a COMPUTED `[String: Any]` (no stored `Any`), so it
/// does not weaken the conformance.
public final class ConvertContext: Sendable {
    /// The SDK that created this context. Strong and immutable: acyclic (the SDK holds no
    /// back-reference) and `Sendable` (``ConvertSwiftSDK`` is `Sendable`).
    private let sdk: ConvertSwiftSDK

    /// The effective visitor identifier resolved at creation by `VisitorContextManager` — an
    /// explicit caller-supplied ID verbatim, else the persisted Keychain/mirror value, else a freshly
    /// generated + persisted `UUID().uuidString`. Immutable for the context's lifetime (bucketing
    /// parity depends on a stable per-context identity).
    public let visitorId: String

    /// The visitor attributes coerced into the closed ``ConvertValue`` scalar set. `Sendable` storage
    /// (``ConvertValue`` is `Sendable`); the public ``attributes`` reconstructs the `[String: Any]`
    /// view from it. Stored as `ConvertValue` rather than raw `Any` so the class stays `Sendable`
    /// with no suppression.
    private let attributesStorage: [String: ConvertValue]

    /// Location properties the LOCATION gate evaluates against (an experience's attached `locations`,
    /// each carrying a rule group). Supplied at `createContext(...:locationProperties:)` and coerced like
    /// ``attributesStorage``. A SEPARATE map from ``attributesStorage`` (the audience gate) — matching the
    /// cross-SDK split (JS/PHP `locationProperties` vs `visitorProperties`; Android's `setLocationProperties`).
    /// Empty by default → an experience WITH `locations` fails the gate (parity with Android's empty-location
    /// behavior); one with no `locations` is unrestricted.
    private let locationPropertiesStorage: [String: ConvertValue]

    /// The SDK's ONE canonical ``DecisionStore``, injected so every context from the same SDK shares
    /// a single store (sticky variations / goal-dedup / segments converge on one instance). `internal`
    /// — the decisioning engines (Stories 3.4 / 4.2) reach it from within the module; it is not part of
    /// the public surface.
    internal let decisionStore: DecisionStore

    /// The SDK's single, fully-wired ``ExperienceManager`` that ``runExperience(_:enableTracking:)``
    /// delegates to (Story 3.4). Injected from ``ConvertSwiftSDK`` (built once over the SDK's canonical
    /// ``decisionStore`` and shared event bus), so every context buckets through the SAME manager —
    /// sticky decisions and `.bucketing` fires converge on the shared instances. ``ExperienceManager``
    /// is a stateless `Sendable` `struct`, so storing it as a `let` keeps this class an all-`let`
    /// `Sendable final class` with no suppression.
    private let experienceManager: ExperienceManager

    /// The SDK's single, fully-wired ``FeatureManager`` that ``runFeature(_:)`` and
    /// ``runFeatures()`` delegate to (Story 4.1). Injected from ``ConvertSwiftSDK`` (built
    /// once over the same ``ExperienceManager`` this context delegates experiences to), so feature
    /// evaluation buckets through the SAME underlying manager — sticky decisions and `.bucketing` fires
    /// converge on the shared instances. ``FeatureManager`` is a stateless `Sendable` `struct`, so
    /// storing it as a `let` keeps this class an all-`let` `Sendable final class` with no suppression.
    private let featureManager: FeatureManager

    /// The SDK's ``EventSink`` this context enqueues the CONVERSION entry through in
    /// ``trackConversion(_:goalData:)`` (Story 4.2, AR14 — events are produced at the ``EventSink``
    /// port, never at a concrete `EventQueue`). Injected from ``ConvertSwiftSDK`` (its `eventSink`, default
    /// ``NoopEventSink`` in production). The ``EventSink`` port refines `Sendable`, so this `let` keeps
    /// the class an all-`let` `Sendable final class` with no suppression.
    private let eventSink: any EventSink

    /// The SDK's shared ``EventBus`` this context fires ``SystemEvent/conversion`` on in
    /// ``trackConversion(_:goalData:)`` (Story 4.2, AC9), so a `sdk.on(.conversion)` subscriber is
    /// notified. The SAME bus the owning ``ConvertSwiftSDK`` exposes through `on`/`off`, so a conversion
    /// fired here reaches the SDK's subscribers. ``EventBus`` is an `actor` (`Sendable`), so this `let`
    /// keeps the class an all-`let` `Sendable final class` with no suppression.
    private let eventBus: EventBus

    /// The SDK's ``Logger`` this context emits its ``trackConversion(_:goalData:)`` drop-path WARNs to
    /// (AOD-6 — the SDK-not-ready and goal-not-found degradations log + drop, never throw). Injected
    /// from ``ConvertSwiftSDK`` (its `logger`, default ``NoopLogger`` in production). The ``Logger`` port
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

    /// The per-context experience-preview state (qs-02 IOS-5): a FRESH ``PreviewState`` actor built
    /// by ``ConvertSwiftSDK/createContext(visitorId:attributes:locationProperties:)`` for THIS
    /// context alone (AC7 isolation — never shared across contexts). Holds the memoized `?exp=`
    /// preview-fetch cache (IOS-4) and, once ``setPreview(experienceId:variationId:)`` resolves
    /// successfully, the forced ``Variation`` that ``runExperience(_:enableTracking:)`` /
    /// ``runExperiences(enableTracking:)`` short-circuit to. An `actor` is `Sendable`, so this `let`
    /// keeps the class an all-`let` `Sendable final class` with no suppression.
    private let previewState: PreviewState

    /// The visitor attributes as a loosely-typed `[String: Any]` map, reconstructed on each access
    /// from the internal ``ConvertValue`` storage via ``ConvertValue/anyValue`` — so a value supplied
    /// as `["age": 30]` reads back as `attributes["age"] as? Int == 30`. A COMPUTED property (no stored
    /// `Any`), which is why it does not weaken the class's `Sendable` conformance. Values that could
    /// not be coerced at creation (nested dictionaries/arrays/etc.) are absent here — they were dropped
    /// because they are not segment-matchable scalars.
    public var attributes: [String: Any] {
        attributesStorage.mapValues { $0.anyValue }
    }

    /// The location properties this context evaluates the location gate against, as a `[String: Any]`
    /// view (mirrors ``attributes``). Empty unless supplied at `createContext(...:locationProperties:)`.
    public var locationProperties: [String: Any] {
        locationPropertiesStorage.mapValues { $0.anyValue }
    }

    /// Binds the context to its creating SDK and its resolved visitor identity. Created only via
    /// ``ConvertSwiftSDK/createContext(visitorId:attributes:)``, which resolves `visitorId` through
    /// ``VisitorContextManager`` and passes the SDK's canonical `decisionStore`.
    ///
    /// `attributes` arrive ALREADY coerced into the closed ``ConvertValue`` set — the
    /// `[String: Any]` → `[String: ConvertValue]` coercion (and the per-key DEBUG log for any
    /// unsupported value that was dropped) happens UPSTREAM in
    /// ``ConvertSwiftSDK/createContext(visitorId:attributes:)``, which holds the SDK's logger. Keeping the
    /// coercion there leaves this context free of a logger dependency; the public
    /// `createContext(attributes:)` parameter stays `[String: Any]?` and the ``attributes`` getter
    /// stays `[String: Any]`, so the loosely-typed surface is unchanged for consumers.
    /// - Parameters:
    ///   - sdk: The creating SDK (held acyclically).
    ///   - visitorId: The already-resolved effective visitor identifier.
    ///   - attributes: The caller-supplied attributes, already coerced to ``ConvertValue`` (unsupported
    ///     values were dropped, and logged at DEBUG, by ``ConvertSwiftSDK/createContext(visitorId:attributes:)``).
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
    ///   - previewState: This context's OWN, freshly-built ``PreviewState`` (qs-02 IOS-5), never
    ///     shared with any other context (AC7 isolation).
    internal init(
        sdk: ConvertSwiftSDK,
        visitorId: String,
        attributes: [String: ConvertValue],
        locationProperties: [String: ConvertValue] = [:],
        decisionStore: DecisionStore,
        experienceManager: ExperienceManager,
        featureManager: FeatureManager,
        eventSink: any EventSink,
        eventBus: EventBus,
        logger: any Logger,
        previewState: PreviewState
    ) {
        self.sdk = sdk
        self.visitorId = visitorId
        self.decisionStore = decisionStore
        self.attributesStorage = attributes
        self.locationPropertiesStorage = locationProperties
        self.experienceManager = experienceManager
        self.featureManager = featureManager
        self.eventSink = eventSink
        self.eventBus = eventBus
        self.logger = logger
        self.previewState = previewState
        // Built over the injected canonical store (not a separate parameter — callers do not pass it), so
        // every context from the same SDK records segments into the ONE store the decisioning path reads.
        self.segmentsManager = SegmentsManager(decisionStore: decisionStore, logger: logger)
    }

    /// Sets an experiment-preview target on this context: `runExperience(_:enableTracking:)` /
    /// `runExperiences(enableTracking:)` will force the given `variationId` for the experience
    /// identified by `experienceId`, bypassing bucketing, rule matching, and stored decisions
    /// entirely (qs-02 Experiment Preview, contract §2 "Decision" / §3 "Precedence").
    ///
    /// ```swift
    /// // given a ready `context` and a parsed deep-link pair
    /// await context.setPreview(experienceId: "9001", variationId: "5002")
    /// let variation = await context.runExperience("pricing-test")   // forced, if the key matches
    /// ```
    ///
    /// Resolves `experienceId` EAGERLY (this call suspends until resolution completes, so a
    /// subsequent `runExperience` sees the outcome immediately): first checks the CURRENT config
    /// snapshot's ``ProjectConfig/rawExperiences`` for an entry whose numeric `id` equals
    /// `experienceId` (the join key `setPreview` receives is the numeric experience id; the
    /// experience is later matched to a `runExperience(_:)` CALL by its string `key`, carried on
    /// the resolved ``Variation/experienceKey``). When absent from the current snapshot, falls back
    /// to the per-context ``PreviewState/resolveConfig(experienceId:)`` `?exp=` fetch (memoized,
    /// 60s TTL, IOS-4) and searches ITS `rawExperiences` the same way.
    ///
    /// **Inert on bad input:** when `experienceId` cannot be resolved (absent from both the local
    /// snapshot AND the fetch) OR ``PreviewDecision/forcedVariation(for:variationId:)`` cannot match
    /// `variationId` within the resolved experience's variations, this WARNs and returns WITHOUT
    /// updating ``PreviewState`` — the context (and any experience it is later asked to run,
    /// including one previously targeted by a successful `setPreview` call) behaves fully normally.
    /// The WARN `message` is ONLY the descriptive tail — the adapter composes the
    /// `[WARN] ConvertContext.setPreview: …` prefix from `type`/`method` (UX-DR19).
    /// - Parameters:
    ///   - experienceId: The numeric experience id to force (from `PreviewParam.parse`'s
    ///     `experienceId`, or supplied directly).
    ///   - variationId: The numeric variation id to force within that experience.
    public func setPreview(experienceId: String, variationId: String) async {
        let localConfig = await sdk.configStore.getSnapshot()
        guard let forced = await resolvePreviewForcedVariation(
            experienceId: experienceId,
            variationId: variationId,
            localConfig: localConfig,
            previewState: previewState
        ) else {
            logPreviewResolutionFailure(logger: logger, experienceId: experienceId, variationId: variationId)
            return
        }
        await previewState.setForcedVariation(forced)
    }

    /// Runs one experience and returns the bucketed ``Variation``, or `nil` when none applies.
    ///
    /// ```swift
    /// // given a ready `context`
    /// if let variation = await context.runExperience("pricing-test") {
    ///     print("Variation \(variation.key)")   // switch your UI on the key
    /// }
    /// ```
    ///
    /// Reads the SDK's current config snapshot from its ``ConfigStore``; a `nil` snapshot (pre-ready,
    /// or a degraded load that resolved with no config) short-circuits to `nil` WITHOUT touching the
    /// manager (AC10 / AOD-6 — the degraded path returns `nil`, never throws). Otherwise delegates to
    /// the injected ``ExperienceManager``, which honours sticky assignment, the audience / location
    /// gates, and `enableTracking`, returning its ``Variation`` (or `nil`) verbatim. Never throws.
    ///
    /// `accountId` / `projectId` come from the snapshot (`account_id` / `project.id`), defaulting to
    /// `""` when absent — they form the sticky store key `"<accountId>-<projectId>-<visitorId>"`, so an
    /// absent id yields a stable (if empty-segmented) key rather than a crash. The LOCATION gate is fed
    /// this context's ``locationProperties`` (supplied at `createContext(...:locationProperties:)`, the
    /// cross-SDK `locationProperties` map — separate from the audience-gate ``attributes``): an
    /// experience with no `locations` is unrestricted and passes regardless; one WITH `locations` matches
    /// only when the supplied properties satisfy a location's rules (empty properties → it fails the gate,
    /// parity with Android's `setLocationProperties`).
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
        // qs-02 IOS-5 / contract §3 (Precedence): a resolved preview target for THIS experience
        // beats stored decisions and normal bucketing — return it BEFORE touching
        // `experienceManager.selectVariation` at all, so sticky lookup / rule matching / the
        // bucketing hash are never consulted for the target. A target set for a DIFFERENT
        // experience key (or no target at all) falls through to the normal path unaffected.
        if let forced = await previewState.forcedVariation, forced.experienceKey == key {
            return forced
        }
        // qs-02 IOS-6 / AC6 (zero-trace): a preview target on THIS context — the forced key above, or
        // ANY OTHER key — suppresses tracking/persistence at the SOURCE for every sibling experience
        // (contract §2). Gated on the PER-CONTEXT `previewState`, never `isTrackingEnabled()` (global).
        let previewActive = await previewState.isPreviewActive
        // AC11: overlay the visitor's persisted segments onto the explicit attribute map so an audience
        // rule can match on a `setDefaultSegments` value (e.g. country). Read under the SAME store key the
        // manager rebuilds internally; explicit createContext attributes still win on collision.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        // Thread the COMBINED gate (FR6 global tracking, per-call `enableTracking`, and IOS-6's
        // `!previewActive`) into the manager: the variation is still selected/persisted/fired, but
        // `BucketingManager` skips the enqueue when ANY flag is false (Story 5.4/5.6; qs-02 IOS-6
        // extends to preview). `persistDecision: !previewActive` also suppresses the sticky WRITE for
        // a sibling under preview (AC6); the sticky READ above is unaffected.
        return await experienceManager.selectVariation(
            forKey: key,
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: stringLocationProperties(),
            enableTracking: await sdk.isTrackingEnabled() && enableTracking && !previewActive,
            persistDecision: !previewActive
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
        stringified(attributesStorage)
    }

    /// The location properties as the `[String: String]` map the LOCATION gate compares against — the
    /// same stringify rule as ``stringAttributes()`` (shared via ``stringified(_:)`` so the two
    /// gate-input builders never diverge). Empty when no location properties were supplied to the context.
    private func stringLocationProperties() -> [String: String] {
        stringified(locationPropertiesStorage)
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

    /// Runs every configured experience for this visitor and returns the bucketed ``Variation`` for
    /// each eligible one, in config order.
    ///
    /// ```swift
    /// // given a ready `context`
    /// for variation in await context.runExperiences() {
    ///     print("\(variation.experienceKey) → \(variation.key)")
    /// }
    /// ```
    ///
    /// Reads the SDK's current config snapshot from its
    /// ``ConfigStore``; a `nil` snapshot (pre-ready / degraded) returns `[]` WITHOUT touching the
    /// manager (AOD-6 — degraded returns empty, never throws). Otherwise delegates to the injected
    /// `ExperienceManager`'s bulk path, which evaluates every experience through
    /// the full single-experience pipeline (sticky /
    /// audience / location / bucket / persist / event) and returns only the eligible variations. A thin
    /// bulk twin of ``runExperience(_:enableTracking:)``.
    ///
    /// `enableTracking` is combined with the SDK's global `network.tracking` flag and the result threaded
    /// to the bulk path, exactly as ``runExperience(_:enableTracking:)`` threads it (run-all mirrors
    /// run-single, not diverge): the per-experience bucketing enqueue is suppressed when EITHER flag is
    /// false (Story 5.4 / FR6), while each variation is still selected, persisted, and fired. `accountId` /
    /// `projectId` come from the snapshot (defaulting to `""` when absent), and `locationProperties` come
    /// from this context — identical to the single-experience path. Never throws.
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
        // qs-02 IOS-5 / contract §2 ("other experiences still evaluate and decide normally") + §3
        // (Precedence): a resolved preview target is EXCLUDED from the bulk config passed to
        // `experienceManager.selectVariations` (a shallow copy with `rawExperiences` filtered by
        // `key`, the ONLY field that method reads) so bucketing/rule-matching/sticky-lookup never
        // runs for the target — mirroring the single-experience short-circuit above — while every
        // sibling experience still decides through the completely normal bulk path. The forced
        // `Variation` is appended afterward so the target's result is still present in the returned
        // array (AC7 isolation test / "forces only the target" test read it back via
        // `experienceKey`, order-independent).
        let forced = await previewState.forcedVariation
        var effectiveConfig = config
        if let forced {
            effectiveConfig.rawExperiences = config.rawExperiences?.filter { $0.key != forced.experienceKey }
        }
        // qs-02 IOS-6 / AC6 (zero-trace): the same per-context gate `runExperience` applies (see its
        // comment) — a preview target suppresses tracking/persistence for every SIBLING experience,
        // not just the (already excluded-from-this-call) forced target. Gated on `previewState`,
        // never the global `isTrackingEnabled()`.
        let previewActive = forced != nil
        // Thread the COMBINED gate (global tracking, per-call `enableTracking`, IOS-6's
        // `!previewActive`) into the bulk path, mirroring the single-experience path (Story 5.4/5.6;
        // qs-02 IOS-6 extends to preview). `persistDecision: !previewActive` suppresses the sticky
        // WRITE for each sibling under preview (AC6).
        var results = await experienceManager.selectVariations(
            in: effectiveConfig,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: stringLocationProperties(),
            enableTracking: await sdk.isTrackingEnabled() && enableTracking && !previewActive,
            persistDecision: !previewActive
        )
        if let forced {
            results.append(forced)
        }
        return results
    }

    /// Resolves one feature flag and returns its ``Feature`` — non-optional by contract, so
    /// the degraded answer is a DISABLED feature (never a throw, AOD-6).
    ///
    /// ```swift
    /// // given a ready `context`
    /// let feature = await context.runFeature("new-checkout")
    /// if feature.status == .enabled { /* show the new checkout */ }
    /// ```
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
    /// `locationProperties` come from this context — as on ``runExperience(_:enableTracking:)``.
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
    ///
    /// qs-02 IOS-fix2 / contract §2 (zero-trace): a preview target on THIS context (any key, not just a
    /// carrying experience's) still suppresses the bucketing enqueue and the sticky WRITE for whichever
    /// experience carries this feature — gated on the PER-CONTEXT `previewState`, never the global
    /// `network.tracking` flag (deliberately NOT combined with it, mirroring the scope asymmetry above:
    /// the feature path stays uncoupled from `isTrackingEnabled()`). The feature itself still RESOLVES
    /// normally (coherent rendering) — only tracking/persistence at the source is suppressed.
    /// - Parameter key: The feature `key` to look up and resolve.
    /// - Returns: The resolved ``Feature`` — `.enabled` with typed variables, or `.disabled` on a
    ///   missing snapshot / miss.
    public func runFeature(_ key: String) async -> Feature {
        guard let config = await sdk.configStore.getSnapshot() else {
            // Pre-ready / degraded: a nil snapshot resolves to a disabled feature without reaching the
            // manager (AOD-6, no throw).
            return Feature.disabled(key: key)
        }
        // qs-02 IOS-fix3 (torn-read close): hoist ONE actor read into a local, mirroring
        // `runExperience(_:enableTracking:)` — two independent `await previewState.isPreviewActive`
        // reads are two separate suspension points, and a concurrent `setPreview` call landing between
        // them could torn-gate `enableTracking`/`persistDecision` from two different preview states
        // (a zero-trace leak risk). A single read closes the window.
        let previewActive = await previewState.isPreviewActive
        // AC11 (JS parity, bd-0ca): overlay the visitor's persisted segments onto the explicit attribute map
        // so the carrying experience's audience gate can match on a `setDefaultSegments` value, exactly as
        // runExperience does — JS context.ts calls getVisitorProperties identically on the feature path.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        // qs-02 IOS-fix2 (AC6 zero-trace): gated on the PER-CONTEXT `previewState`, never
        // `isTrackingEnabled()` (global) — see the doc comment above for why this is NOT combined
        // with the global flag on this path.
        return await featureManager.evaluateFeature(
            key: key,
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: stringLocationProperties(),
            enableTracking: !previewActive,
            persistDecision: !previewActive
        )
    }

    /// Resolves every feature in the config and returns its ``Feature``, in config order.
    ///
    /// ```swift
    /// // given a ready `context`
    /// for feature in await context.runFeatures() where feature.status == .enabled {
    ///     print("enabled: \(feature.key)")
    /// }
    /// ```
    ///
    /// Reads the SDK's current config snapshot from its ``ConfigStore``; a `nil` snapshot (pre-ready /
    /// degraded) returns `[]` WITHOUT touching the manager (AOD-6 — degraded returns empty, never throws),
    /// the feature twin of ``runExperiences(enableTracking:)``. Otherwise delegates to the injected
    /// ``FeatureManager/evaluateAllFeatures(in:visitorId:accountId:projectId:attributes:locationProperties:)``,
    /// which enumerates `config.features` and resolves each through the single-feature path. `accountId` /
    /// `projectId` come from the snapshot (defaulting to `""` when absent) and `locationProperties` come
    /// from this context — identical to the single-feature path. Never throws.
    ///
    /// As with ``runFeature(_:)``, this method takes NO `enableTracking` parameter (Android parity, F-171):
    /// the feature path is not per-call tracking-gated.
    ///
    /// qs-02 IOS-fix2 / contract §2 (zero-trace): same per-context `previewState` gate as
    /// ``runFeature(_:)`` applies to every feature evaluated here — see its doc comment for the scope
    /// asymmetry rationale (deliberately NOT combined with `isTrackingEnabled()`).
    /// - Returns: One ``Feature`` per `config.features` entry, in config order; `[]` on a missing
    ///   snapshot.
    public func runFeatures() async -> [Feature] {
        guard let config = await sdk.configStore.getSnapshot() else {
            return []
        }
        // qs-02 IOS-fix3 (torn-read close): same single-read hoist as `runFeature(_:)` — see its
        // comment for why two independent `await previewState.isPreviewActive` reads are a torn-gate
        // risk under a concurrent `setPreview` call.
        let previewActive = await previewState.isPreviewActive
        // AC11 (JS parity, bd-0ca): same segment overlay as the single-feature path (run-all mirrors
        // run-single, not diverge) — each feature's carrying-experience audience gate sees the visitor's
        // persisted segments.
        let segments = await decisionStore.currentSegments(forVisitorKey: storeKey(for: config))
        let attributes = mergedAttributes(stringAttributes(), with: segments)
        // qs-02 IOS-fix2 (AC6 zero-trace): gated on the PER-CONTEXT `previewState`, never the global
        // `isTrackingEnabled()` — mirrors `runFeature(_:)`.
        return await featureManager.evaluateAllFeatures(
            in: config,
            visitorId: visitorId,
            accountId: config.accountId ?? "",
            projectId: config.project?.id ?? "",
            attributes: attributes,
            locationProperties: stringLocationProperties(),
            enableTracking: !previewActive,
            persistDecision: !previewActive
        )
    }

    /// Tracks a conversion for `goalKey`, optionally carrying per-goal ``GoalData`` metrics, with a
    /// per-visitor dedup gate and an opt-in multiple-transactions override.
    ///
    /// ```swift
    /// // given a ready `context`
    /// await context.trackConversion("purchase-goal", goalData: [.amount: .double(49.99)])
    /// ```
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
    /// method (precedent: `ConvertSwiftSDK.init` / `ExperienceManager.selectVariation` in this codebase) rather
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
        // qs-02 IOS-6 / AC6 (zero-trace): a preview target on THIS context suppresses conversion
        // tracking ENTIRELY — the dedup persist below, both enqueues, and the `.conversion` bus fire.
        // Gated on the PER-CONTEXT `previewState`, never the global `isTrackingEnabled()`.
        guard !(await previewState.isPreviewActive) else { return }
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
        // Runtime tracking gate (FR6 / Story 5.6): async read of the actor-isolated flag. Placed AFTER
        // the dedup write above so the dedup mark persists even when tracking is off (Story 5.6 / AC4).
        // When OFF, NO entry enters the `EventSink` on EITHER gate below — but the dedup mark STILL
        // persists and the local `.conversion` bus signal STILL fires on first trigger (JS parity:
        // `context.ts` fires `SystemEvents.CONVERSION` on trigger independent of the network gate —
        // only delivery to the queue is suppressed). Exactly ONE DEBUG line records the suppression
        // for this call (Story 5.4 / AC6); the message is a fixed descriptive tail carrying NO SDK key /
        // secret (NFR6). [Source: Story 5.6 / AC1, AC4; Story 5.4 / AC5, AC6]
        let networkTrackingOn = await sdk.isTrackingEnabled()
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
    /// ```swift
    /// // given a ready `context`
    /// await context.setDefaultSegments(["country": "US", "visitorType": "returning"])
    /// ```
    ///
    /// `async` but NEVER throws (AOD-6). Delegates the merge to ``SegmentsManager`` (each of the six
    /// recognised string keys overlays the visitor's existing segments; unknown keys WARN and are
    /// ignored), reads the resolved ``Segments`` back from the shared `decisionStore`, and fires
    /// ``SystemEvent/segments`` ONCE with a ``SegmentsPayload`` carrying them (AC12). A `nil` config
    /// snapshot (pre-ready / degraded) means there is no account/project to form the sticky store key —
    /// it WARNs and returns WITHOUT firing, the same degrade ``trackConversion(_:goalData:forceMultipleTransactions:)``
    /// applies on a not-ready SDK. The WARN `message` is ONLY the descriptive tail; the adapter composes
    /// the `[WARN] ConvertContext.setDefaultSegments: …` prefix from `type`/`method` (UX-DR19).
    /// - Parameter segments: The wire-keyed string segment fields to merge (`country`, `browser`,
    ///   `devices`, `source`, `campaign`, `visitorType`); unrecognised keys are ignored with a WARN.
    /// [Source: AC1, AC12]
    public func setDefaultSegments(_ segments: [String: String]) async {
        // qs-02 IOS-6 / AC6 (zero-trace): a preview target on THIS context suppresses the segments
        // update ENTIRELY — no delegation to the shared `SegmentsManager`, no persist, no `.segments`
        // bus fire. Gated on the PER-CONTEXT `previewState`, never the global `isTrackingEnabled()`.
        guard !(await previewState.isPreviewActive) else { return }
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
    /// ```swift
    /// // given a ready `context`
    /// await context.setCustomSegments(["vip", "beta-tester"])
    /// ```
    ///
    /// `async` but NEVER throws (AOD-6). Delegates the append to ``SegmentsManager`` (the ids are added to
    /// the visitor's existing `customSegments`; backend owns dedup, matching JS), reads the resolved
    /// ``Segments`` back from the shared `decisionStore`, and fires ``SystemEvent/segments`` ONCE with a
    /// ``SegmentsPayload`` (AC12). A `nil` config snapshot (pre-ready / degraded) WARNs and returns WITHOUT
    /// firing — the same not-ready degrade as ``setDefaultSegments(_:)``.
    /// - Parameter segmentIds: The custom segment identifiers to append to the visitor's `customSegments`.
    /// [Source: AC2, AC12]
    public func setCustomSegments(_ segmentIds: [String]) async {
        // qs-02 IOS-6 / AC6 (zero-trace): a preview target on THIS context suppresses the custom
        // segments update ENTIRELY — no delegation to the shared `SegmentsManager`, no persist, no
        // `.segments` bus fire. Gated on the PER-CONTEXT `previewState`, never the global
        // `isTrackingEnabled()`.
        guard !(await previewState.isPreviewActive) else { return }
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

/// Stringifies a coerced ``ConvertValue`` map to the `[String: String]` form the rule/segment engine
/// compares against (a string stays itself; int/double/bool render via their `String(_:)` initialisers).
/// Shared by ``ConvertContext/stringAttributes()`` (audience gate) and
/// ``ConvertContext/stringLocationProperties()`` (location gate) so neither re-derives the switch (DRY —
/// keeps the diff under the SonarQube CPD gate).
///
/// A file-scope function (not a `ConvertContext` method — it touches no `self` state, only its
/// parameter) so it does not count against the class's `type_body_length` budget (qs-02 IOS-fix3;
/// precedent: ``mergedAttributes(_:with:)`` /
/// ``resolvePreviewForcedVariation(experienceId:variationId:localConfig:previewState:)`` below).
/// `file_length` is already disabled file-wide for this file (see the top-of-file rationale), so
/// this move adds no NEW suppression.
private func stringified(_ values: [String: ConvertValue]) -> [String: String] {
    values.mapValues { value in
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        }
    }
}

/// Overlays the visitor's non-nil string segment fields onto the explicit attribute map so audience
/// rules can match on `country`/`visitorType`/etc. Explicit attributes WIN on key collision (the
/// caller's createContext attribute is more specific than a stored segment). `customSegments` is an
/// array, not a scalar attribute, so it is NOT overlaid. [Source: AC11]
///
/// A file-scope function (not a `ConvertContext` method — it touches no `self` state, only its two
/// parameters) so it does not count against the class's `type_body_length` budget (qs-02 IOS-6;
/// precedent: ``resolvePreviewForcedVariation(experienceId:variationId:localConfig:previewState:)``
/// below). `file_length` is already disabled file-wide for this file (see the top-of-file
/// rationale), so this move adds no NEW suppression.
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

/// Resolves the ``Variation`` forced by an experiment-preview target (qs-02 IOS-5,
/// ``ConvertContext/setPreview(experienceId:variationId:)``): checks `localConfig`'s
/// ``ProjectConfig/rawExperiences`` for an entry whose numeric `id` equals `experienceId` FIRST;
/// when absent, falls back to `previewState`'s memoized `?exp=` fetch
/// (``PreviewState/resolveConfig(experienceId:)``) and searches ITS `rawExperiences` the same
/// way. Once the experience is found (from either source), matches `variationId` via
/// ``PreviewDecision/forcedVariation(for:variationId:)``.
///
/// A file-scope function (not a `ConvertContext` method) so it does not count against the
/// class's `type_body_length` budget — `file_length` is already disabled file-wide for this file
/// (see the top-of-file rationale), so this helper adds no NEW suppression.
/// - Parameters:
///   - experienceId: The numeric experience id to resolve (the join key ``ConvertContext``
///     receives from `setPreview`; the experience's STRING `key`, carried on the returned
///     ``Variation/experienceKey``, is what a later `runExperience(_:)` call is matched against).
///   - variationId: The numeric variation id to force within the resolved experience.
///   - localConfig: The context's current config snapshot, checked first.
///   - previewState: The context's own ``PreviewState``, whose memoized fetch is the fallback.
/// - Returns: The forced ``Variation``, or `nil` when the experience or variation could not be
///   resolved (inert-on-bad-input — the caller logs the WARN).
private func resolvePreviewForcedVariation(
    experienceId: String,
    variationId: String,
    localConfig: ProjectConfig?,
    previewState: PreviewState
) async -> Variation? {
    let experience: Components.Schemas.ConfigExperience?
    if let localMatch = localConfig?.rawExperiences?.first(where: { $0.id == experienceId }) {
        experience = localMatch
    } else {
        let fetchedConfig = await previewState.resolveConfig(experienceId: experienceId)
        experience = fetchedConfig?.rawExperiences?.first { $0.id == experienceId }
    }
    guard let experience else { return nil }
    return PreviewDecision.forcedVariation(for: experience, variationId: variationId)
}

/// Logs the `setPreview` inert-on-bad-input WARN when
/// ``resolvePreviewForcedVariation(experienceId:variationId:localConfig:previewState:)`` returns
/// `nil` — a file-scope helper (see that function's placement rationale) so this stays out of
/// ``ConvertContext``'s `type_body_length` budget. The `message` is ONLY the descriptive tail —
/// the adapter composes the `[WARN] ConvertContext.setPreview: …` prefix from `type`/`method`
/// (UX-DR19).
/// - Parameters:
///   - logger: The context's ``Logger`` to emit the WARN to.
///   - experienceId: The unresolved preview target's experience id, echoed in the message.
///   - variationId: The unresolved preview target's variation id, echoed in the message.
private func logPreviewResolutionFailure(logger: any Logger, experienceId: String, variationId: String) {
    logger.log(
        level: .warn,
        type: "ConvertContext",
        method: "setPreview",
        message: "preview target experienceId '\(experienceId)' / variationId '\(variationId)' "
            + "could not be resolved — falling through to normal decisions."
    )
}

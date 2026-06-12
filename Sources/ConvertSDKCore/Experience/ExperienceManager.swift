// ExperienceManager.swift
// Sticky-aware single-experience decisioning (Epic 3 / Story 4).
// Foundation-only — part of the pure-logic ConvertSDKCore target.
//
// PARITY NOTE — this composes the in-scope subset of the Convert JavaScript SDK's
// `runExperience` path for ONE experience:
//   1. Unknown experience key → nil (the `fullExperience(forKey:)` miss short-circuits).
//   2. A pre-seeded sticky decision short-circuits — the stored variation is rebuilt and
//      returned with NO bucket, NO enqueue, and NO `.bucketing` EventBus fire (a sticky hit is
//      not a NEW decision).
//   3. AUDIENCE gate: an EMPTY resolved audience set is UNRESTRICTED (passes — parity JS:435,
//      the bd-d4p empty-list rule); a non-empty set's rules are flattened and OR-combined across
//      every attached audience, then evaluated against `attributes` (a fail returns nil).
//   4. LOCATION gate: the same shape over `locations` against `locationProperties` (empty ⇒ pass).
//   5. BUCKET via ``BucketingManager/bucket(visitorId:experience:enableTracking:)`` — that call
//      owns the single bucketing enqueue (driven by `enableTracking`); this type NEVER enqueues.
//   6. PERSIST the new decision; FIRE `.bucketing` on the bus — only on a NEW decision.
//
// SCOPE (bd-d4p) — the audience/location combine is a FLAT OR across the attached objects'
// groups (visitor matches if ANY object's rules match). The per-audience ALL/ANY
// `matching_options` semantics are DEFERRED. `site_area` (the alternative to `locations` on the
// generated `ConfigExperience`) is NOT gated here: only the `locations` list drives the location
// gate, so a `site_area`-only experience is treated as location-unrestricted (passes). The EM
// suite does not exercise `site_area`; gating it is deferred with the rest of bd-d4p.
//
// STATELESS / Sendable: a plain `struct` whose stored dependencies are each `Sendable`
// (``RuleManager``/``BucketingManager`` structs, ``DecisionStore``/``EventBus`` actors,
// ``Logger``), so the type is `Sendable` with no suppression. `selectVariation` is `async` only
// because its collaborators are; it NEVER throws — every failure mode degrades to `nil`.

import Foundation

/// Selects the variation a visitor is assigned for a single experience, honouring sticky
/// assignment, the audience and location gates, and the `enableTracking` flag.
///
/// `public` (with the `internal init` kept for `@testable` construction in
/// `ExperienceManagerTests`): the cross-module ``ConvertSDK`` target stores this type on its
/// ``ConvertContext`` and calls
/// ``selectVariation(forKey:in:visitorId:accountId:projectId:attributes:locationProperties:enableTracking:)``
/// (the full signature is documented on that method), so both the type and that one method are part
/// of the SDK-facing surface. Its collaborators —
/// ``RuleManager``, ``BucketingManager``, ``NoopEventSink`` — stay `internal`: the SDK never
/// constructs them, it calls the single public ``makeDefault(decisionStore:eventBus:logger:)``
/// factory, which wires them inside this module. This keeps the newly-public surface to exactly
/// the manager, `selectVariation`, and `makeDefault`.
public struct ExperienceManager: Sendable {
    /// Evaluates the flattened audience / location rule groups (OR-of-AND).
    private let ruleManager: RuleManager
    /// Performs the deterministic bucket — and the single bucketing enqueue when tracking is on.
    private let bucketingManager: BucketingManager
    /// Reads the sticky decision and persists a new one.
    private let decisionStore: DecisionStore
    /// Receives the `.bucketing` system event fired on a NEW decision.
    private let eventBus: EventBus
    /// Sink for the diagnostic warnings emitted on the degrade paths.
    private let logger: Logger

    /// Injects the five collaborators. `bucketingManager` owns the bucketing enqueue (this type
    /// holds no `EventSink` and never enqueues); `eventBus` receives only the new-decision fire.
    init(
        ruleManager: RuleManager,
        bucketingManager: BucketingManager,
        decisionStore: DecisionStore,
        eventBus: EventBus,
        logger: Logger
    ) {
        self.ruleManager = ruleManager
        self.bucketingManager = bucketingManager
        self.decisionStore = decisionStore
        self.eventBus = eventBus
        self.logger = logger
    }

    /// Builds a fully-wired ``ExperienceManager`` from the dependencies the SDK already owns — the
    /// ONE public entry point a cross-module caller (``ConvertSDK``) uses, so it never touches the
    /// `internal` ``RuleManager`` / ``BucketingManager`` / ``NoopEventSink`` collaborators directly.
    ///
    /// Wires:
    ///   * ``RuleManager`` over `logger` — evaluates the flattened audience / location rule groups.
    ///   * ``BucketingManager`` over a ``NoopEventSink`` and `logger` — performs the deterministic
    ///     bucket. The sink is the production default until Epic 5's `EventQueue` is built
    ///     (bead bd-2pb): the bucketing enqueue is PRODUCED at the ``EventSink`` boundary but
    ///     discarded by ``NoopEventSink`` until the real queue replaces it HERE (the single swap
    ///     site). This does not weaken the Story 3.4 contract — the seam is exercised; only the
    ///     downstream destination is deferred.
    ///   * `decisionStore` / `eventBus` — passed through verbatim so the manager reads/persists
    ///     sticky decisions on, and fires `.bucketing` on, the SAME instances the SDK shares across
    ///     every context (sticky parity + `.bucketing` subscribers both depend on shared identity).
    ///
    /// - Parameters:
    ///   - decisionStore: The SDK's canonical sticky-decision store (shared across every context).
    ///   - eventBus: The SDK's shared bus — the manager fires `.bucketing` on it for new decisions.
    ///   - logger: The diagnostic sink for the manager and its collaborators.
    /// - Returns: A wired ``ExperienceManager`` ready to call
    ///   ``selectVariation(forKey:in:visitorId:accountId:projectId:attributes:locationProperties:enableTracking:)``.
    public static func makeDefault(
        decisionStore: DecisionStore,
        eventBus: EventBus,
        logger: Logger
    ) -> ExperienceManager {
        ExperienceManager(
            ruleManager: RuleManager(logger: logger),
            bucketingManager: BucketingManager(eventSink: NoopEventSink(), logger: logger),
            decisionStore: decisionStore,
            eventBus: eventBus,
            logger: logger
        )
    }

    // The eight parameters are the pinned call contract (the visitor/account/project triple, the two
    // gate data maps, the key, the config, and the tracking flag are each a distinct input the
    // pipeline needs); collapsing them into a struct would only relocate the same arity behind a
    // value type. The committed `ExperienceManagerTests` invoke this exact labelled signature, so the
    // shape is fixed by test. Targeted disable (precedent: `MurmurHash3.swift`) rather than raising
    // the project-wide threshold. The directive is on the `func` line below so the `///` doc comment
    // stays flush against the declaration (avoids `orphaned_doc_comment`).
    /// Resolves the variation `visitorId` is assigned for the experience keyed `key`.
    ///
    /// Returns `nil` when the key is unknown, the experience has no id, an audience or location
    /// gate fails, or the visitor buckets outside the allocated traffic. On a sticky hit the stored
    /// variation is returned directly (no bucket / enqueue / fire). On a NEW decision the bucket
    /// performs the single enqueue (when `enableTracking`), the decision is persisted, and the
    /// `.bucketing` event is fired. Never throws.
    ///
    /// - Parameters:
    ///   - key: The experience `key` looked up via ``ProjectConfig/fullExperience(forKey:)``.
    ///   - config: The decoded project config the experience and its audiences/locations live in.
    ///   - visitorId: The visitor being bucketed.
    ///   - accountId: Account id — the first segment of the sticky store key.
    ///   - projectId: Project id — the second segment of the sticky store key.
    ///   - attributes: The data map the audience gate evaluates against.
    ///   - locationProperties: The data map the location gate evaluates against.
    ///   - enableTracking: When `false`, suppresses the bucketing enqueue (passed through to the
    ///     bucket step); the variation is still selected, persisted, and fired.
    /// - Returns: The assigned ``Variation``, or `nil` on any short-circuit / gate failure / miss.
    public func selectVariation( // swiftlint:disable:this function_parameter_count
        forKey key: String,
        in config: ProjectConfig,
        visitorId: String,
        accountId: String,
        projectId: String,
        attributes: [String: String],
        locationProperties: [String: String],
        enableTracking: Bool
    ) async -> Variation? {
        // 1. Resolve the full experience and its id (the id keys sticky / persist).
        guard let full = config.fullExperience(forKey: key), let experienceId = full.id else {
            return nil
        }
        let storeKey = "\(accountId)-\(projectId)-\(visitorId)"

        // 2. STICKY short-circuit — return the stored variation with no bucket / enqueue / fire.
        if let sticky = await stickyVariation(
            forExperience: experienceId, storeKey: storeKey, full: full
        ) {
            return sticky
        }

        // 3–4. AUDIENCE then LOCATION gate (an empty resolved set is unrestricted / passes).
        guard audiencePasses(full, in: config, attributes: attributes),
              locationPasses(full, in: config, locationProperties: locationProperties) else {
            return nil
        }

        // 5. BUCKET — this performs the single enqueue when `enableTracking`; a miss returns nil.
        guard let variation = await bucketingManager.bucket(
            visitorId: visitorId, experience: full, enableTracking: enableTracking
        ) else {
            return nil
        }

        // 6. PERSIST the new decision, then FIRE `.bucketing` (only on a NEW decision).
        await decisionStore.saveDecision(
            variationId: variation.id, experienceId: experienceId, storeKey: storeKey
        )
        await eventBus.fire(
            .bucketing,
            payload: .bucketing(BucketingPayload(
                experienceId: experienceId, variationId: variation.id, visitorId: visitorId
            ))
        )
        return variation
    }

    // The seven parameters mirror `selectVariation`'s call contract minus the single `key` (the bulk
    // form enumerates keys from the config itself). Like its singular sibling this exceeds SwiftLint's
    // default `function_parameter_count` warning threshold (5); a targeted disable on the `func` line
    // (precedent: `selectVariation` above) keeps the `///` doc flush against the declaration (avoids
    // `orphaned_doc_comment`) rather than raising the project-wide threshold.
    /// Resolves the bucketed ``Variation`` for EVERY eligible experience in `config`, in config order.
    ///
    /// A thin bulk wrapper over
    /// ``selectVariation(forKey:in:visitorId:accountId:projectId:attributes:locationProperties:enableTracking:)``
    /// — it adds NO decisioning logic of its own. It enumerates ``ProjectConfig/rawExperiences`` (the
    /// deterministic, decoded config order) and feeds each element's `key` through the FULL
    /// single-experience pipeline (sticky → audience → location → bucket → persist → `.bucketing` fire).
    /// All sticky resolution, rule evaluation, bucketing, ``DecisionStore`` access, and ``EventBus``
    /// interaction stay owned by that one call; this method only enumerates, threads inputs, and
    /// collects.
    ///
    /// Invariants:
    ///   * NO duplicated decision logic — the loop body's sole decisioning call is `selectVariation`.
    ///   * CONFIG ORDER — results are appended in `rawExperiences` array order; an excluded experience
    ///     never reorders the survivors.
    ///   * STRAIGHT-THROUGH TRACKING — `enableTracking` is forwarded UNCHANGED to each per-experience
    ///     bucket (the per-call FR19 flag). The global `network.tracking` gate is an Epic 5 concern and
    ///     is NOT resolved here.
    ///   * NEVER THROWS — `selectVariation` degrades every failure mode to `nil`, so the loop is
    ///     naturally crash-proof (AC9): an experience the visitor is ineligible for (unknown key, no id,
    ///     audience/location gate fail, below-traffic bucket, or sticky-nil) returns `nil` and is
    ///     silently excluded WITHOUT aborting the loop. Evaluated SEQUENTIALLY (one experience at a
    ///     time) — not in parallel — to keep the ``DecisionStore`` actor interaction simple and the
    ///     collected order deterministic.
    ///
    /// - Parameters:
    ///   - config: The decoded project config whose ``ProjectConfig/rawExperiences`` are enumerated;
    ///     `nil`/empty yields `[]`.
    ///   - visitorId: The visitor being bucketed (forwarded to each `selectVariation`).
    ///   - accountId: Account id — the first segment of the sticky store key.
    ///   - projectId: Project id — the second segment of the sticky store key.
    ///   - attributes: The data map each experience's audience gate evaluates against.
    ///   - locationProperties: The data map each experience's location gate evaluates against.
    ///   - enableTracking: Forwarded UNCHANGED to every per-experience bucket; when `false` the bucketing
    ///     enqueue is suppressed (the variation is still selected, persisted, and fired).
    /// - Returns: The assigned ``Variation`` for every eligible experience, in config order; `[]` when
    ///   the config has no experiences or the visitor is eligible for none.
    public func selectVariations( // swiftlint:disable:this function_parameter_count
        in config: ProjectConfig,
        visitorId: String,
        accountId: String,
        projectId: String,
        attributes: [String: String],
        locationProperties: [String: String],
        enableTracking: Bool
    ) async -> [Variation] {
        guard let experiences = config.rawExperiences, !experiences.isEmpty else { return [] }
        var results: [Variation] = []
        results.reserveCapacity(experiences.count)
        for experience in experiences {
            // Skip an element with no `key` (cannot look it up) defensively — fixtures always carry a
            // key, but a `nil` here must continue the loop, not crash. `selectVariation` owns every
            // decision for the looked-up experience; a `nil` result is silently excluded.
            guard let key = experience.key else { continue }
            if let variation = await selectVariation(
                forKey: key,
                in: config,
                visitorId: visitorId,
                accountId: accountId,
                projectId: projectId,
                attributes: attributes,
                locationProperties: locationProperties,
                enableTracking: enableTracking
            ) {
                results.append(variation)
            }
        }
        return results
    }

    /// Rebuilds the sticky ``Variation`` for `experienceId` under `storeKey`, or `nil` when no
    /// sticky decision is stored. The stored variation id is matched back onto `full`'s variations
    /// to recover its `key`; an id with no matching variation still returns a `Variation` carrying
    /// an empty `key` so a stored decision is honoured even if the config dropped the variation.
    private func stickyVariation(
        forExperience experienceId: String,
        storeKey: String,
        full: Components.Schemas.ConfigExperience
    ) async -> Variation? {
        guard let stickyVarId = await decisionStore.stickyVariationId(
            forExperience: experienceId, storeKey: storeKey
        ) else {
            return nil
        }
        let matched = full.variations?.first { $0.id == stickyVarId }
        return Variation(
            id: stickyVarId,
            key: matched?.key ?? "",
            experienceId: experienceId,
            experienceKey: full.key ?? ""
        )
    }

    /// Whether the experience's AUDIENCE gate passes for `attributes`.
    ///
    /// An EMPTY resolved audience set is UNRESTRICTED → `true` (parity: an experience with no
    /// audiences runs for everyone). Otherwise every attached audience's rules are flattened and
    /// CONCATENATED into one outer-OR (the visitor matches if ANY audience's rules match), then
    /// evaluated by ``RuleManager`` (which fails closed on an empty group).
    private func audiencePasses(
        _ full: Components.Schemas.ConfigExperience,
        in config: ProjectConfig,
        attributes: [String: String]
    ) -> Bool {
        let audiences = (full.audiences ?? []).compactMap { config.audience(id: $0) }
        guard !audiences.isEmpty else { return true }
        let groups = audiences.flatMap { audience -> [RuleGroup] in
            guard let rules = audience.rules?.value1 else { return [] }
            return RuleAdapter.flatten(rules)
        }
        return ruleManager.evaluate(rules: groups, against: attributes)
    }

    /// Whether the experience's LOCATION gate passes for `locationProperties`.
    ///
    /// Mirrors ``audiencePasses(_:in:attributes:)`` over the experience's `locations`: an EMPTY
    /// resolved location set is UNRESTRICTED → `true`; otherwise every attached location's rules are
    /// flattened and concatenated into one outer-OR, then evaluated against `locationProperties`.
    /// `site_area` is NOT consulted (deferred, bd-d4p), so a `locations`-empty experience passes.
    private func locationPasses(
        _ full: Components.Schemas.ConfigExperience,
        in config: ProjectConfig,
        locationProperties: [String: String]
    ) -> Bool {
        let locations = (full.locations ?? []).compactMap { config.location(id: $0) }
        guard !locations.isEmpty else { return true }
        let groups = locations.flatMap { location -> [RuleGroup] in
            guard let rules = location.rules?.value1 else { return [] }
            return RuleAdapter.flatten(rules)
        }
        return ruleManager.evaluate(rules: groups, against: locationProperties)
    }
}

// FeatureManager.swift
// Feature-flag evaluation with typed variables (Epic 4 / Story 1).
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.
//
// Resolves a `config.features[]` entry to a `Feature` by delegating ALL bucketing to
// `ExperienceManager.selectVariation`. A feature is ENABLED iff the visitor buckets into a
// variation whose `fullStackFeature` change carries it (`String(change.data.feature_id) ==
// feature.id`); the variable VALUES come from that change's `variables_data`, each TYPED by the
// matching `features[].variables[].type`. An unknown key, an uncarried feature, or a carrier the
// visitor never buckets into all yield `Feature.disabled(key:)`.
//
// DELEGATION — this type owns NO decisioning of its own: it never touches `EventBus`,
// `BucketingManager`, `RuleManager`, `DecisionStore`, or any `EventSink`. The sole bucketing call
// is `experienceManager.selectVariation(...)`, so the sticky / audience / location / traffic /
// enqueue / `.bucketing`-fire contract is the EM's verbatim (a config where nothing buckets fires
// nothing — the feature path invents no event). `selectVariation` never throws (it degrades every
// failure to `nil`), so this type never throws either.
//
// MULTI-CARRIER POLICY (deliberate) — a feature MAY be referenced by `fullStackFeature` changes in
// more than one experience. `evaluateFeature` walks `config.rawExperiences` in CONFIG ORDER and
// returns the FIRST associated experience the visitor buckets into (config-order first-match wins).
// An associated experience the visitor does NOT bucket into is skipped (the feature might still be
// carried by a later one); only when NO associated experience buckets does the feature resolve
// disabled. `selectVariation` is therefore called AT MOST once per ASSOCIATED experience and NEVER
// for an experience that does not reference the feature (AC14).

import Foundation

/// Evaluates feature flags for a visitor, delegating all bucketing to ``ExperienceManager``.
///
/// `public` (mirroring ``ExperienceManager``'s public composition surface) because ``ConvertSwiftSDK`` is a
/// SEPARATE module that depends on this `ConvertSwiftSDKCore` target: its composition root builds the one
/// shared instance and ``ConvertContext`` delegates `runFeature` / `runFeatures` to it, both of which
/// need this type — and the `evaluateFeature` / `evaluateAllFeatures` / `init` it calls — visible across
/// the module boundary. A plain `struct` of `Sendable` members (``ExperienceManager``, ``Logger``), so
/// the type is `Sendable` with no suppression. `evaluateFeature` / `evaluateAllFeatures` are `async`
/// only because the delegated `selectVariation` is; neither throws.
public struct FeatureManager: Sendable {
    /// Delegate that owns the single-experience bucketing pipeline (sticky → audience → location →
    /// bucket → persist → `.bucketing` fire). The ONLY collaborator this type calls into.
    private let experienceManager: ExperienceManager
    /// Diagnostic sink for the population-layer warnings (feature-not-found, variable type mismatch).
    private let logger: Logger

    /// Composes the feature evaluator over its bucketing delegate. `public` (mirroring
    /// ``ExperienceManager``'s public composition surface) so the separate `ConvertSwiftSDK` module's
    /// composition root can build the one shared instance — the compiler-synthesized memberwise init
    /// is `internal` and therefore invisible across the module boundary, so this explicit `public`
    /// init is required for cross-module wiring.
    /// - Parameters:
    ///   - experienceManager: The bucketing delegate every evaluation routes through.
    ///   - logger: Diagnostic sink for population-layer warnings.
    public init(experienceManager: ExperienceManager, logger: Logger) {
        self.experienceManager = experienceManager
        self.logger = logger
    }

    // The seven parameters are the pinned call contract (the feature key, the config, the
    // visitor/account/project triple, and the two gate data maps are each a distinct input the
    // delegated `selectVariation` needs); the committed `FeatureManagerTests` invoke this exact
    // labelled signature, so the shape is fixed by test. Targeted disable (precedent:
    // `ExperienceManager.selectVariation`) rather than raising the project-wide threshold. The
    // directive is on the `func` line below so the `///` doc comment stays flush against the
    // declaration (avoids `orphaned_doc_comment`).
    /// Resolves the feature keyed `key` for the visitor into a ``Feature``.
    ///
    /// Returns `.disabled(key:)` when the key is absent from `config.features`, the matched feature
    /// has no id, no experience references it, or no associated experience buckets the visitor. When
    /// an associated experience DOES bucket (config-order first match wins — see the multi-carrier
    /// note on the type), returns an `.enabled` feature whose `variables` are read from that winning
    /// change's `variables_data`, each typed by the matching `features[].variables[].type`. Never
    /// throws.
    ///
    /// - Parameters:
    ///   - key: The feature `key` looked up in `config.features`.
    ///   - config: The decoded project config the feature and its carrying experiences live in.
    ///   - visitorId: The visitor being bucketed (forwarded to `selectVariation`).
    ///   - accountId: Account id — forwarded to `selectVariation` (sticky store key segment).
    ///   - projectId: Project id — forwarded to `selectVariation` (sticky store key segment).
    ///   - attributes: The data map each carrying experience's audience gate evaluates against.
    ///   - locationProperties: The data map each carrying experience's location gate evaluates against.
    /// - Returns: The resolved ``Feature`` — `.enabled` with typed variables, or `.disabled`.
    public func evaluateFeature( // swiftlint:disable:this function_parameter_count
        key: String,
        in config: ProjectConfig,
        visitorId: String,
        accountId: String,
        projectId: String,
        attributes: [String: String],
        locationProperties: [String: String]
    ) async -> Feature {
        // 1. Look up the feature; a miss is a population-layer warning, then disabled.
        guard let feature = config.features?.first(where: { $0.key == key }) else {
            warn("evaluateFeature", "feature '\(key)' not found in config")
            return .disabled(key: key)
        }
        // 2. A feature with no id can't be matched against a change's `feature_id`.
        guard let featureId = feature.id else { return .disabled(key: key) }

        // 3. Walk experiences in CONFIG ORDER; the first associated one the visitor buckets wins.
        for experience in config.rawExperiences ?? [] {
            // 3a. Skip experiences that don't reference this feature (no selectVariation call).
            guard experienceCarries(experience, featureId: featureId), let expKey = experience.key else {
                continue
            }
            // 3b. Delegate the full bucketing decision for this experience.
            let variation = await experienceManager.selectVariation(
                forKey: expKey,
                in: config,
                visitorId: visitorId,
                accountId: accountId,
                projectId: projectId,
                attributes: attributes,
                locationProperties: locationProperties,
                enableTracking: true
            )
            // 3c. Visitor not bucketed into this carrier — a later experience might still carry it.
            guard let variation else { continue }
            // 3d. Bucketed: populate from the winning variation's matching change and return.
            let data = featureChangeData(forFeatureId: featureId, in: experience, variationId: variation.id)
            let variables = buildVariables(from: data?.variables_data, feature: feature)
            return Feature(id: featureId, key: key, status: .enabled, variables: variables)
        }
        // 4. No associated experience bucketed the visitor.
        return .disabled(key: key)
    }

    // The six parameters mirror `evaluateFeature`'s call contract minus the single `key` (the bulk
    // form enumerates keys from `config.features` itself); like its singular sibling this exceeds
    // SwiftLint's default `function_parameter_count` threshold (5) and is fixed by the committed
    // tests. Targeted disable on the `func` line (precedent: `evaluateFeature` above) keeps the `///`
    // doc flush against the declaration (avoids `orphaned_doc_comment`) rather than raising the
    // project-wide threshold.
    /// Resolves EVERY feature in `config.features` into a ``Feature``, in config order.
    ///
    /// A thin bulk wrapper over
    /// ``evaluateFeature(key:in:visitorId:accountId:projectId:attributes:locationProperties:)`` — it
    /// adds no logic of its own beyond enumerating `config.features` and threading the inputs. A
    /// config with no features yields `[]`.
    ///
    /// - Parameters:
    ///   - config: The decoded project config whose `features` are enumerated; absent/empty yields `[]`.
    ///   - visitorId: The visitor being bucketed (forwarded to each `evaluateFeature`).
    ///   - accountId: Account id — forwarded to each `evaluateFeature`.
    ///   - projectId: Project id — forwarded to each `evaluateFeature`.
    ///   - attributes: The data map each feature's carrying experiences' audience gates evaluate against.
    ///   - locationProperties: The data map each feature's carrying experiences' location gates evaluate against.
    /// - Returns: One ``Feature`` per `config.features` entry, in config order; `[]` when empty.
    public func evaluateAllFeatures( // swiftlint:disable:this function_parameter_count
        in config: ProjectConfig,
        visitorId: String,
        accountId: String,
        projectId: String,
        attributes: [String: String],
        locationProperties: [String: String]
    ) async -> [Feature] {
        guard let features = config.features, !features.isEmpty else { return [] }
        var results: [Feature] = []
        results.reserveCapacity(features.count)
        for feature in features {
            guard let key = feature.key else { continue }
            let resolved = await evaluateFeature(
                key: key,
                in: config,
                visitorId: visitorId,
                accountId: accountId,
                projectId: projectId,
                attributes: attributes,
                locationProperties: locationProperties
            )
            results.append(resolved)
        }
        return results
    }

    // MARK: - Carrier resolution

    /// Whether `experience` references the feature `featureId` — i.e. ANY of its variations carries a
    /// `fullStackFeature` change whose `data.feature_id` (an `Int`) stringifies to `featureId`. Used
    /// to skip experiences that don't carry the feature so `selectVariation` fires only for carriers.
    private func experienceCarries(
        _ experience: Components.Schemas.ConfigExperience,
        featureId: String
    ) -> Bool {
        for variation in experience.variations ?? [] where variationCarries(variation, featureId: featureId) {
            return true
        }
        return false
    }

    /// Whether `variation` carries a `fullStackFeature` change bound to `featureId`.
    private func variationCarries(
        _ variation: Components.Schemas.ExperienceVariationConfig,
        featureId: String
    ) -> Bool {
        for change in variation.changes ?? [] {
            if case let .fullStackFeature(serving) = change,
               let changeFeatureId = serving.value2.value2.data?.feature_id,
               String(changeFeatureId) == featureId {
                return true
            }
        }
        return false
    }

    /// The `fullStackFeature` change `dataPayload` bound to `featureId` on the WINNING variation
    /// (`variationId`) of `experience`, or `nil` when the variation or the matching change is absent.
    /// The variation is matched back by id (mirroring ``ExperienceManager`` sticky resolution) so the
    /// populated variables come from the change the visitor actually bucketed into.
    private func featureChangeData(
        forFeatureId featureId: String,
        in experience: Components.Schemas.ConfigExperience,
        variationId: String
    ) -> Components.Schemas.ExperienceChangeFullStackFeatureBase.Value2Payload.dataPayload? {
        guard let variation = experience.variations?.first(where: { $0.id == variationId }) else {
            return nil
        }
        for change in variation.changes ?? [] {
            if case let .fullStackFeature(serving) = change,
               let data = serving.value2.value2.data,
               let changeFeatureId = data.feature_id,
               String(changeFeatureId) == featureId {
                return data
            }
        }
        return nil
    }

    // MARK: - Variable typing

    /// Builds the typed `[String: FeatureVariable]` map for an enabled feature by joining the change's
    /// `variables_data` VALUES to the feature's declared variable TYPES (`features[].variables[]`) by
    /// name. A variable whose value is absent or whose type doesn't match is logged (population-layer
    /// warning) and SKIPPED — an enabled feature with a partially-typed map is valid; the missing
    /// variable simply isn't present, so ``Feature/variable(_:as:)`` returns `nil` for it.
    private func buildVariables(
        from variablesData: OpenAPIObjectContainer?,
        feature: Components.Schemas.ConfigFeature
    ) -> [String: FeatureVariable] {
        var result: [String: FeatureVariable] = [:]
        for featureVar in feature.variables ?? [] {
            guard let varName = featureVar.key, let varType = featureVar._type else { continue }
            // `variables_data.value[name]` is `(any Sendable)??` — flatten the double optional.
            let rawValue = variablesData?.value[varName].flatMap { $0 }
            if let typed = featureVariable(type: varType, rawValue: rawValue) {
                result[varName] = typed
            } else {
                warn("evaluateFeature", "variable '\(varName)' type mismatch")
            }
        }
        return result
    }

    /// Maps one declared variable `type` + its raw `variables_data` value to a typed ``FeatureVariable``,
    /// or `nil` when the value is absent or not castable to the declared type.
    ///
    /// `.float` also accepts an `Int` (a whole-number JSON value like `5` decodes as `Int` via the
    /// `OpenAPIValueContainer` Bool→Int→Double ladder) so a float variable carrying a whole number
    /// still types. `.json` re-serializes the nested container to `Data` (see ``jsonData(from:)``).
    private func featureVariable(
        type: Components.Schemas.FeatureVariableItemData._typePayload,
        rawValue: (any Sendable)?
    ) -> FeatureVariable? {
        switch type {
        case .boolean:
            return (rawValue as? Bool).map(FeatureVariable.boolean)
        case .integer:
            return (rawValue as? Int).map(FeatureVariable.integer)
        case .float:
            if let double = rawValue as? Double { return .float(double) }
            if let int = rawValue as? Int { return .float(Double(int)) }
            return nil
        case .string:
            return (rawValue as? String).map(FeatureVariable.string)
        case .json:
            return jsonData(from: rawValue).map(FeatureVariable.json)
        }
    }

    // MARK: - JSON variable serialization

    /// Re-serializes a `json`-typed variable's raw value (a nested object/array stored as
    /// `[String: (any Sendable)?]` / `[(any Sendable)?]`) back to `Data`, or `nil` when the value is
    /// absent or not a JSON container. The optionals in the dynamic value are unwrapped to a Foundation
    /// JSON object first (``jsonObject(from:)``), since `JSONSerialization` requires NSNull/NSNumber/
    /// NSString leaves and a top-level object or array.
    private func jsonData(from value: (any Sendable)?) -> Data? {
        guard let object = jsonObject(from: value),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Recursively converts a dynamic `(any Sendable)?` JSON value into a Foundation-serializable
    /// `Any`: dictionaries and arrays recurse (unwrapping each element's optional, `nil` → `NSNull`),
    /// `Bool`/`Int`/`Double`/`String` pass through. Returns `nil` for an unsupported leaf so a bad
    /// value degrades rather than crashing the population pass.
    private func jsonObject(from value: (any Sendable)?) -> Any? {
        guard let value else { return NSNull() }
        if let dictionary = value as? [String: (any Sendable)?] {
            return dictionary.mapValues { jsonObject(from: $0) ?? NSNull() }
        }
        if let array = value as? [(any Sendable)?] {
            return array.map { jsonObject(from: $0) ?? NSNull() }
        }
        switch value {
        case let bool as Bool: return bool
        case let int as Int: return int
        case let double as Double: return double
        case let string as String: return string
        default: return nil
        }
    }

    // MARK: - Logging

    /// Emits a population-layer `.warn` line in the structured `[LEVEL] {Type}.{method}: {message}`
    /// shape (UX-DR19), tagged to this type. Centralized so every warn call site shares the format.
    private func warn(_ method: String, _ message: String) {
        logger.log(level: .warn, type: "FeatureManager", method: method, message: message)
    }
}

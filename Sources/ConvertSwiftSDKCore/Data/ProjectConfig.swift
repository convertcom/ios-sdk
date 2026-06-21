// ProjectConfig.swift
// Hand-authored DEGRADING decode root for CDN config (Epic 2 / Story 3).
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// The decode root for a Convert CDN project config: a degrading wrapper over the wire shape
/// of the generated ``Components/Schemas/ConfigResponseData``.
///
/// ── Why a degrading root (NOT the raw generated type) ────────────────────────────────────
/// The live CDN baseline does NOT decode through the raw generated `ConfigResponseData`: four
/// measured backend drifts make a straight `JSONDecoder.decode` throw, which would abort config
/// loading entirely. ``init(from:)`` therefore decodes the root FIELD BY FIELD and degrades each
/// non-decodable sub-tree (to `nil`, or to the `.sentinel` arm of a ``SentinelWrapped``) instead
/// of throwing, so a single drifted sub-tree never costs the whole config:
///   - **D1** `project.utc_offset` arrives as the wire String `"0"`, but generated
///     `ConfigProject.utc_offset` is `UTC_Offset = Int` → a raw decode throws `typeMismatch`.
///     Disposition: ``Project/utcOffset`` is `nil`.
///   - **D2** `project.settings.integrations.google_analytics` arrives as the discriminator-absent
///     LCD `{"enabled":false}` → a raw `GA_Settings` (`oneOf` keyed on `type`) decode throws
///     `keyNotFound`. Disposition: the `.sentinel` arm of ``GASettingsOrSentinel`` (it never throws).
///   - **D3** `goals[].type` is the wire String `"advanced"` but the composed `ConfigGoalBase.type`
///     is an array → a raw element decode throws `typeMismatch`. Disposition: each goal decodes
///     through ``ConfigGoalOrSentinel`` (sentinel on the collision), so all goals are retained.
///   - **D4** `experiences[].type` is the wire String `"a/b_fullstack"`, which is NOT a case of the
///     generated `ExperienceTypes` enum → a raw decode throws `dataCorrupted`. Disposition: the
///     experience survives and its ``Experience/type`` is `nil`.
///
/// ── How the degrade is localized (NOT a boundary catch) ──────────────────────────────────
/// Every degrade is a per-field `try?` inside a typed `init(from:)`, mirroring the sanctioned
/// ``SentinelWrapped`` mechanism. There is deliberately NO top-level `do { decode the whole root }
/// catch { }` boundary catch: the root is decoded one field at a time, so the failure of one field
/// cannot drop a sibling that decoded fine.
///
/// ── Decoder contract (AR13) ──────────────────────────────────────────────────────────────
/// Decoded with a plain `JSONDecoder` and NO `keyDecodingStrategy`. The generated config types
/// carry literal snake_case `CodingKeys`, so `.convertFromSnakeCase` is forbidden — this wrapper
/// maps wire snake_case → camelCase property names with explicit ``CodingKeys`` instead.
public struct ProjectConfig: Decodable, Sendable {
    /// Account ID under which the project exists (wire `account_id`). Survives the degrade so the
    /// decoded config is usable for bucketing.
    public var accountId: String?
    /// The degrading project sub-tree (wire `project`). `nil` only when the field is absent; a
    /// drifted-but-present project still decodes because ``Project`` degrades per-field.
    public var project: ProjectConfig.Project?
    /// Goals decoded as sentinel-or-known (wire `goals`, D3): each element decodes through
    /// ``ConfigGoalOrSentinel`` so the `"advanced"` String-vs-array collision sentinels rather than
    /// throwing, retaining every goal.
    public var goals: [ConfigGoalOrSentinel]?
    /// Experiences decoded tolerantly (wire `experiences`, D4): each element keeps its `id` and
    /// degrades an unknown ``Experience/type`` to `nil` rather than throwing, retaining every entry.
    public var experiences: [ProjectConfig.Experience]?
    /// The FULL generated experiences (wire `experiences`), retained alongside the stripped
    /// ``experiences`` so sticky-assignment lookups can reach `key` and the `variations` array that
    /// the stripped ``Experience`` drops. Decoded PER-ELEMENT (each element under its own `try?` via
    /// ``DegradingExperience``) so a single drifted element — e.g. the `"a/b_fullstack"` value absent
    /// from the generated `ExperienceTypes` enum — degrades out alone WITHOUT a whole-array
    /// `dataCorrupted` throw nulling its valid siblings. `nil` when the field is absent or every
    /// element degraded. Queried via ``fullExperience(forKey:)``.
    public var rawExperiences: [Components.Schemas.ConfigExperience]?
    /// Audiences (wire `audiences`) — the generated element type decodes cleanly in the baseline.
    public var audiences: [Components.Schemas.ConfigAudience]?
    /// Segments (wire `segments`) — the generated element type decodes cleanly in the baseline.
    public var segments: [Components.Schemas.ConfigSegment]?
    /// Locations (wire `locations`) — the generated element type decodes cleanly in the baseline.
    public var locations: [Components.Schemas.ConfigLocation]?
    /// Features (wire `features`) — the generated element type decodes cleanly in the baseline.
    public var features: [Components.Schemas.ConfigFeature]?

    /// Wire keys for the `ConfigResponseData` root, mapping snake_case → camelCase property names
    /// (AR13 — explicit keys, never `.convertFromSnakeCase`).
    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case project
        case goals
        case experiences
        case audiences
        case segments
        case locations
        case features
    }

    // The wire-key enums for the nested ``Project`` / ``Experience`` sub-trees are declared at this
    // (``ProjectConfig``) scope rather than inside those structs. They are a private decode detail,
    // and hoisting them one level keeps the nested-type depth within SwiftLint's `nesting` limit
    // while preserving the public `ProjectConfig.Project` / `ProjectConfig.Experience` shape the
    // contract requires.

    /// Wire keys at the `ConfigProject` level (the `settings` allOf is flattened on the wire, so
    /// `integrations` is reached by descending `settings` directly — there is no `value1` wire key).
    private enum ProjectKeys: String, CodingKey {
        case id
        case utcOffset = "utc_offset"
        case settings
    }

    /// Wire keys inside the flattened `settings` object.
    private enum ProjectSettingsKeys: String, CodingKey {
        case integrations
    }

    /// Wire keys inside the `integrations` object.
    private enum ProjectIntegrationsKeys: String, CodingKey {
        case googleAnalytics = "google_analytics"
    }

    /// Wire keys at the `ConfigExperience` level.
    private enum ExperienceKeys: String, CodingKey {
        case id
        case type
    }

    /// Decodes the `ConfigResponseData` root field-by-field, degrading each non-decodable sub-tree
    /// instead of throwing. Each `try?` is the localized sentinel mechanism: a sub-tree that throws
    /// degrades to `nil` (or, for goals, sentinels per element) without affecting its siblings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try? container.decodeIfPresent(String.self, forKey: .accountId)
        project = try? container.decodeIfPresent(ProjectConfig.Project.self, forKey: .project)
        // D3: SentinelWrapped never throws on well-formed JSON, so the whole array decodes with
        // each drifted goal landing on `.sentinel` — all entries retained.
        goals = try? container.decodeIfPresent([ConfigGoalOrSentinel].self, forKey: .goals)
        // D4: each Experience degrades its own `type`, so the array decode retains every element.
        experiences = try? container.decodeIfPresent(
            [ProjectConfig.Experience].self,
            forKey: .experiences
        )
        // PC-1: retain the FULL generated experiences too, decoded PER-ELEMENT. A whole-array
        // `try? decode([ConfigExperience])` would throw on the first drifted element (e.g. the
        // unknown `"a/b_fullstack"` type → `dataCorrupted`) and the `try?` would null the ENTIRE
        // array, losing valid siblings. Decoding each element through `DegradingExperience` (whose
        // `init` never throws — it `try?`s the real type) keeps the unkeyed-container index always
        // advancing by exactly one, so the loop terminates and a bad element degrades out alone.
        if var rawArray = try? container.nestedUnkeyedContainer(forKey: .experiences) {
            var collected: [Components.Schemas.ConfigExperience] = []
            while !rawArray.isAtEnd {
                // LOOP-TERMINATION INVARIANT: `DegradingExperience.init` NEVER throws (it `try?`s the
                // real `ConfigExperience` decode internally), so `rawArray.decode(DegradingExperience
                // .self)` ALWAYS succeeds and advances the unkeyed-container index by EXACTLY one per
                // iteration — the `isAtEnd` guard is therefore guaranteed to flip after at most
                // `count` iterations and the loop terminates. The outer `try?` is defensive/unreachable
                // (the decode cannot throw). Do NOT remove the never-throws property of
                // `DegradingExperience`: a throwing element decode here would leave the index un-
                // advanced on a bad element, spinning this `while` FOREVER. (A drifted element still
                // degrades out alone — `wrapped.experience` is `nil` — without nulling its siblings.)
                if let wrapped = try? rawArray.decode(DegradingExperience.self),
                   let experience = wrapped.experience {
                    collected.append(experience)
                }
            }
            rawExperiences = collected.isEmpty ? nil : collected
        }
        audiences = try? container.decodeIfPresent(
            [Components.Schemas.ConfigAudience].self,
            forKey: .audiences
        )
        segments = try? container.decodeIfPresent(
            [Components.Schemas.ConfigSegment].self,
            forKey: .segments
        )
        locations = try? container.decodeIfPresent(
            [Components.Schemas.ConfigLocation].self,
            forKey: .locations
        )
        features = try? container.decodeIfPresent(
            [Components.Schemas.ConfigFeature].self,
            forKey: .features
        )
    }

    /// The FULL generated experience whose `key` equals `key`, or `nil` when no retained experience
    /// matches (an unknown key, or an element that degraded out of ``rawExperiences``). Returns the
    /// FULL ``Components/Schemas/ConfigExperience`` — `key`, `variations`, and the rest — not the
    /// stripped ``Experience``, so sticky-variation assignment can read the variations array.
    public func fullExperience(forKey key: String) -> Components.Schemas.ConfigExperience? {
        rawExperiences?.first { $0.key == key }
    }

    /// The audience whose `id` equals `id` in the decoded ``audiences`` array, or `nil` for an
    /// unknown id (lookup miss, not a degrade).
    public func audience(id: String) -> Components.Schemas.ConfigAudience? {
        audiences?.first { $0.id == id }
    }

    /// The location whose `id` equals `id` in the decoded ``locations`` array, or `nil` for an
    /// unknown id (lookup miss, not a degrade).
    public func location(id: String) -> Components.Schemas.ConfigLocation? {
        locations?.first { $0.id == id }
    }

    /// The embedded ``Components/Schemas/ConfigGoalBase`` (carrying `id`/`key`/`name`) of the goal
    /// whose `key` equals `key`, or `nil` when no goal matches. The conversion-tracking path uses it
    /// to map a caller's goalKey → the wire goalId (the base's `id`).
    ///
    /// ── Why this reads the `.sentinel` payload, NOT the `.known` arm (D3) ─────────────────────
    /// On the wire every goal carries `type` as a bare String discriminator (`"advanced"`, …).
    /// Decoding through ``ConfigGoalOrSentinel`` therefore ALWAYS lands on `.sentinel`, never
    /// `.known`: ``Components/Schemas/ConfigGoal/init(from:)`` selects its `oneOf` case from the
    /// String `type`, then the composed ``Components/Schemas/ConfigGoalBase/_type`` is typed
    /// `[GoalTypes]` (an array) and the scalar String collides → `typeMismatch` → the wrapper falls
    /// back to `.sentinel` (drift D3, see the type doc above). The `.sentinel` `JSONValue` payload
    /// RETAINS every field (`id`/`key`/`name`/`type`), so this resolves the base from that payload.
    /// A reader that inspected only the `.known` arm would return `nil` for EVERY real goal and
    /// silently break goalKey→goalId resolution. The `.known` arm is still handled (a future schema
    /// fix could make goals decode `.known`); a goal whose `.sentinel` payload lacks a `key` — or
    /// whose `key` does not match — is simply skipped, never crashed.
    public func goal(forKey key: String) -> Components.Schemas.ConfigGoalBase? {
        goals?.lazy.compactMap(Self.goalBase(from:)).first { $0.key == key }
    }

    /// Extracts the embedded ``Components/Schemas/ConfigGoalBase`` from ONE goal element regardless
    /// of which ``SentinelWrapped`` arm it decoded to: the `.value1` base for a (today unreachable)
    /// `.known` goal, or a base reconstructed from the retained `JSONValue` payload for a `.sentinel`
    /// goal (the production reality — see ``goal(forKey:)``). `nil` only if a sentinel payload is not
    /// a JSON object (which a well-formed goal never is).
    private static func goalBase(from goal: ConfigGoalOrSentinel) -> Components.Schemas.ConfigGoalBase? {
        switch goal {
        case let .known(configGoal):
            return base(fromKnown: configGoal)
        case let .sentinel(payload):
            return base(fromSentinelPayload: payload)
        }
    }

    /// The composed ``Components/Schemas/ConfigGoalBase`` (`value1`) of a decoded
    /// ``Components/Schemas/ConfigGoal``. Every `oneOf` arm composes the base as its `value1`, so the
    /// switch reaches it uniformly. Unreachable for production goal `type` today (they sentinel —
    /// D3), but handled so a future `.known`-decoding goal still resolves.
    private static func base(fromKnown goal: Components.Schemas.ConfigGoal) -> Components.Schemas.ConfigGoalBase {
        switch goal {
        case let .advanced(value): return value.value1
        case let .clicks_element(value): return value.value1
        case let .clicks_link(value): return value.value1
        case let .code_trigger(value): return value.value1
        case let .dom_interaction(value): return value.value1
        case let .ga_import(value): return value.value1
        case let .revenue(value): return value.value1
        case let .scroll_percentage(value): return value.value1
        case let .submits_form(value): return value.value1
        case let .visits_page(value): return value.value1
        }
    }

    /// Reconstructs a ``Components/Schemas/ConfigGoalBase`` from a `.sentinel` goal's retained
    /// `JSONValue` payload by reading the `id`/`name`/`key` string members. `_type`/`rules` are left
    /// `nil`: the scalar wire `type` cannot populate `[GoalTypes]` (that collision is WHY the goal
    /// sentinels), and the conversion path needs only `id`/`key`. `nil` when the payload is not a
    /// JSON object (a well-formed goal is always an object, so real goals always reconstruct).
    private static func base(fromSentinelPayload payload: JSONValue) -> Components.Schemas.ConfigGoalBase? {
        guard case let .object(pairs) = payload else { return nil }
        return Components.Schemas.ConfigGoalBase(
            id: stringValue(of: "id", in: pairs),
            name: stringValue(of: "name", in: pairs),
            key: stringValue(of: "key", in: pairs)
        )
    }

    /// The `String` value of the `name`-keyed member in a `JSONValue` object's pairs, or `nil` when
    /// the member is absent or not a JSON string. Centralizes the `.object` member read so the
    /// sentinel reconstruction never inlines the find-then-unwrap per field.
    private static func stringValue(of name: String, in pairs: [JSONValue.Pair]) -> String? {
        guard case let .string(value)? = pairs.first(where: { $0.key == name })?.value else {
            return nil
        }
        return value
    }

    /// The degrading project sub-tree. Each field degrades independently so a drifted field
    /// (D1 `utc_offset`, D2 GA) never throws the whole project away.
    public struct Project: Decodable, Sendable {
        /// Project ID (wire `id`). Survives the degrade so the config is usable for bucketing.
        public var id: String?
        /// UTC offset (wire `utc_offset`, D1). `nil` when the wire value is NOT an `Int` — the
        /// baseline ships the String `"0"`, so `decodeIfPresent(Int.self)` throws `typeMismatch`
        /// and the `try?` converts that to `nil` rather than failing the decode.
        public var utcOffset: Int?
        /// GA project settings (wire path `settings` → `integrations` → `google_analytics`, D2),
        /// decoded through ``GASettingsOrSentinel`` so the discriminator-absent LCD
        /// `{"enabled":false}` lands on `.sentinel` instead of throwing. `nil` only when an
        /// intermediate object (`settings`/`integrations`) or the `google_analytics` field is
        /// absent — each descent level is guarded so a missing parent degrades to `nil`.
        public var googleAnalytics: GASettingsOrSentinel?

        /// Decodes the project field-by-field. `id` decodes straight; `utcOffset` and the GA
        /// sub-tree degrade via localized `try?` so D1/D2 never throw the project away. (Wire-key
        /// enums live at the ``ProjectConfig`` scope — see the note there.)
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: ProjectKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            // D1: String "0" makes the Int decode throw typeMismatch → degraded to nil.
            utcOffset = try? container.decodeIfPresent(Int.self, forKey: .utcOffset)
            // D2: descend settings → integrations defensively; a missing intermediate keyed
            // container makes `nestedContainer` throw, which `try?` degrades to nil. Decoding the
            // GA value through GASettingsOrSentinel never throws — the LCD payload sentinels.
            let settings = try? container.nestedContainer(
                keyedBy: ProjectSettingsKeys.self,
                forKey: .settings
            )
            let integrations = try? settings?.nestedContainer(
                keyedBy: ProjectIntegrationsKeys.self,
                forKey: .integrations
            )
            googleAnalytics = try? integrations?.decodeIfPresent(
                GASettingsOrSentinel.self,
                forKey: .googleAnalytics
            )
        }
    }

    /// A tolerant experience sub-tree (D4): keeps its `id` and degrades an unknown `type` to `nil`
    /// rather than throwing, so an experience with a future/unknown type still survives the decode.
    public struct Experience: Decodable, Sendable {
        /// Experience ID (wire `id`). Survives the degrade so the experience is identifiable.
        public var id: String?
        /// Experience type (wire `type`, D4). `nil` when the wire value is not a known
        /// `ExperienceTypes` case — the baseline's `"a/b_fullstack"` is absent from the generated
        /// enum, so the decode throws `dataCorrupted` and the `try?` converts that to `nil`.
        public var type: Components.Schemas.ExperienceTypes?

        /// Decodes the experience field-by-field. `id` decodes straight; `type` degrades to `nil`
        /// for an unknown wire value via the localized `try?`. (Wire-key enum lives at the
        /// ``ProjectConfig`` scope — see the note there.)
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: ExperienceKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            // D4: an unknown enum value throws dataCorrupted → degraded to nil.
            type = try? container.decodeIfPresent(
                Components.Schemas.ExperienceTypes.self,
                forKey: .type
            )
        }
    }
}

/// Decodes ONE `experiences` array element permissively for ``ProjectConfig/rawExperiences``: its
/// `init(from:)` ALWAYS succeeds (it `try?`s the real ``Components/Schemas/ConfigExperience`` decode),
/// capturing the experience when the element decodes and leaving ``experience`` `nil` otherwise. That
/// guarantee is load-bearing: when used with `UnkeyedDecodingContainer.decode(_:)`, a non-throwing
/// element decode advances the container index by EXACTLY one per call, so the per-element retention
/// loop in ``ProjectConfig/init(from:)`` always terminates (bounded by the array length) AND a single
/// drifted element — e.g. an unknown `type` enum value that throws `dataCorrupted` — degrades to `nil`
/// without aborting the whole array. File-private (depth 0) to stay within SwiftLint `nesting`.
private struct DegradingExperience: Decodable {
    /// The decoded experience, or `nil` when this element failed to decode (degraded out).
    let experience: Components.Schemas.ConfigExperience?

    init(from decoder: any Decoder) throws {
        // NEVER rethrows — load-bearing: a failing `ConfigExperience` decode (e.g. unknown `type`)
        // becomes `nil` rather than propagating. This is the property the per-element retention loop
        // in `ProjectConfig.init(from:)` relies on for termination: because this `init` cannot throw,
        // `UnkeyedDecodingContainer.decode(DegradingExperience.self)` always advances the container
        // index by exactly one. If this were ever made to rethrow, a bad element would leave the index
        // un-advanced and spin that loop forever. Do NOT remove the `try?`.
        experience = try? Components.Schemas.ConfigExperience(from: decoder)
    }
}

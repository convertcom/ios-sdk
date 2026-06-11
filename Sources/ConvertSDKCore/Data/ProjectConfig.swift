// ProjectConfig.swift
// Hand-authored DEGRADING decode root for CDN config (Epic 2 / Story 3).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

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

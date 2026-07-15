// ProjectConfig+AudienceDecoding.swift
// Hand-authored per-audience DEGRADING decode (D5, IOS-1 mobile mutual-exclusion, mirrors the
// `rawExperiences` per-element loop in ProjectConfig.swift). Foundation-only — part of the
// pure-logic ConvertSwiftSDKCore target.
//
// Split into its OWN file purely to keep `ProjectConfig.swift` under SwiftLint's `file_length` /
// `function_body_length` gates — this logic is a direct extension of `ProjectConfig.init(from:)`
// (see the D5 note there), not an independent feature, and shares its `stringValue(of:in:)`
// helper (elevated from `private` to internal for that reuse — see the doc there).

import Foundation

extension ProjectConfig {
    /// Decodes an ALREADY-OPENED `audiences` unkeyed container per-element through
    /// `SentinelWrapped<Components.Schemas.ConfigAudience>` (never throws — see
    /// `PolymorphicSentinels.swift`) so a single audience whose rule tree embeds an unknown
    /// `rule_type` discriminator (e.g. `bucketed_into_experience_key`) degrades out ALONE:
    /// SIBLING audiences are retained untouched, and the offending audience is NOT dropped — it
    /// is reconstructed as a placeholder (``reconstructAudience(fromSentinelPayload:)``) so it
    /// stays retrievable via ``ProjectConfig/audience(id:)``, with its raw payload returned
    /// alongside for ``ProjectConfig/degradedAudienceSentinels``.
    ///
    /// ── LOOP-TERMINATION INVARIANT (mirrors `DegradingExperience` in ProjectConfig.swift) ──────
    /// `SentinelWrapped<Known>.init(from:)` NEVER throws on well-formed JSON (any failure to
    /// decode `Known` falls back to `.sentinel`, capturing the raw payload instead of
    /// propagating), so `rawAudiences.decode(SentinelWrapped<Components.Schemas.ConfigAudience>
    /// .self)` ALWAYS succeeds and advances the unkeyed-container index by EXACTLY one per
    /// iteration — the `isAtEnd` guard is therefore guaranteed to flip after at most `count`
    /// iterations and the loop terminates. The `try?` around the decode call is
    /// defensive/unreachable (the decode cannot throw for a well-formed element). Do NOT rely on
    /// a throwing decode here: it would leave the index un-advanced on a bad element and spin
    /// this `while` FOREVER.
    ///
    /// - Parameter rawAudiences: The `audiences` field's unkeyed container, already opened by the
    ///   caller (`ProjectConfig.init(from:)`) via `container.nestedUnkeyedContainer(forKey:
    ///   .audiences)`.
    /// - Returns: The retained audiences (`nil` when the array was empty or every element
    ///   degraded with no recoverable payload) and the sentinel payloads captured for degraded
    ///   audiences, keyed by their recovered `id` (`nil` when none degraded).
    static func decodeDegradingAudiences(
        from rawAudiences: inout UnkeyedDecodingContainer
    ) -> (audiences: [Components.Schemas.ConfigAudience]?, sentinels: [String: JSONValue]?) {
        var collectedAudiences: [Components.Schemas.ConfigAudience] = []
        var collectedSentinels: [String: JSONValue] = [:]
        while !rawAudiences.isAtEnd {
            if let wrapped = try? rawAudiences.decode(
                SentinelWrapped<Components.Schemas.ConfigAudience>.self
            ) {
                switch wrapped {
                case let .known(audience):
                    collectedAudiences.append(audience)
                case let .sentinel(payload):
                    let reconstructed = reconstructAudience(fromSentinelPayload: payload)
                    collectedAudiences.append(reconstructed)
                    if let id = reconstructed.id {
                        collectedSentinels[id] = payload
                    }
                }
            }
        }
        return (
            collectedAudiences.isEmpty ? nil : collectedAudiences,
            collectedSentinels.isEmpty ? nil : collectedSentinels
        )
    }

    /// Reconstructs a placeholder ``Components/Schemas/ConfigAudience`` from a `.sentinel`
    /// payload's `id`/`key`/`name` members (D5) so an audience whose rule tree embeds an unknown
    /// `rule_type` discriminator remains retrievable via ``ProjectConfig/audience(id:)`` instead
    /// of being silently dropped. `rules` is left `nil`: the payload's rule tree is exactly the
    /// sub-tree that failed to decode (that is WHY it sentineled) — a future rule-level consumer
    /// (IOS-2) reads the raw leaf off ``ProjectConfig/degradedAudienceSentinels`` instead of this
    /// placeholder's `rules`. `_type` is likewise left `nil` — not needed by any current consumer
    /// of a degraded audience, and reconstructing it would require re-deriving a
    /// `ConfigAudienceTypes` case from a raw String with no caller today to exercise it.
    /// `id`/`key`/`name` are `nil` only when the payload is not a JSON object (a well-formed
    /// audience is always an object) or omits that member.
    static func reconstructAudience(
        fromSentinelPayload payload: JSONValue
    ) -> Components.Schemas.ConfigAudience {
        guard case let .object(pairs) = payload else {
            return Components.Schemas.ConfigAudience()
        }
        return Components.Schemas.ConfigAudience(
            id: stringValue(of: "id", in: pairs),
            key: stringValue(of: "key", in: pairs),
            name: stringValue(of: "name", in: pairs)
        )
    }
}

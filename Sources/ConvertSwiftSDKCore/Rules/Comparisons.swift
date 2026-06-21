// Sources/ConvertSwiftSDKCore/Rules/Comparisons.swift
// Per-operator rule-evaluation comparator for audience / location matching (Epic 3 / Story 3).
//
// PARITY NOTE — JavaScript SDK is ground truth. Every operator below mirrors the LIVE
// `javascript-sdk/packages/utils/src/comparisons.ts` (verified line-by-line), NOT the
// story's terser operator table, which is lossy in seven places that are each pinned by a
// test vector in ComparisonsTests.swift:
//   1. `equals`/`equalsNumber`/`matches` are case-INSENSITIVE (lowercase both); `equalsNumber`
//      and `matches` ALIAS `equals` — string equality, NOT numeric compare (JS 37-43).
//   2. `contains` is case-INSENSITIVE; `value` is the HAYSTACK and `testAgainst` the NEEDLE;
//      an empty / whitespace-only needle returns true (JS 78-86).
//   3. `startsWith` / `endsWith` are case-INSENSITIVE — lowercase both (JS 122-140).
//   4. `less` / `lessEqual` are TYPE-GUARDED: a non-numeric operand on either side yields
//      false (mirrors JS `typeof value !== typeof testAgainst → false`), never a crash. The
//      numeric gate (`numeric(_:)`) mirrors JS `isNumeric` (string-utils.ts:68-74): it REJECTS
//      sci-notation / hex / `Infinity` / leading-plus and ACCEPTS comma-grouped thousands, so a
//      bare `Double()` can't silently widen what counts as numeric (bd-vh1).
//   5. `regexMatches` is case-INSENSITIVE (JS `'i'` flag); an invalid pattern yields false.
//   6. `isIn` is ASYMMETRIC: the `value` candidates are NOT lowercased; the `testAgainst`
//      allow-list IS lowercased (JS 95-108).
//   7. `exists` / `not_exists` treat the EMPTY STRING as ABSENT; `doesNotExist` aliases
//      `not_exists` (JS 159-173).
// Negation inverts the result of every real operator at the end of `evaluate`
// (`_returnNegationCheck`, JS 175-184). An unknown operator fails closed: it logs a WARN and
// returns false directly, WITHOUT negation applied (the JS rule-manager returns false for an
// unsupported match type — the fail-closed false is terminal and must not be inverted).
//
// DISPATCH SHAPE — the wire `matchType` is resolved through a static `[String: comparator]`
// table rather than a `switch`. A 10-way `switch` trips SwiftLint's `cyclomatic_complexity`
// (each `case` is a decision point); a dictionary literal has none, so the lookup keeps
// `evaluate` at minimal complexity while still reading as a dispatch table. Every comparator
// shares the uniform `(String?, String?) -> Bool` signature so it can be a table value —
// `exists` / `notExists` accept (and ignore) the second argument to fit that shape.
//
// Foundation-only: `NSRegularExpression` backs `regexMatches`; nothing else here needs a
// platform framework. A stateless `enum` with pure static functions is inherently `Sendable`.

import Foundation

/// Stateless namespace mapping a wire `matchType` string to its parity-matched comparison.
///
/// Pure functions only — there is intentionally no instance state and this is NOT an actor:
/// the comparator is a referentially transparent dispatch table over `(value, testAgainst)`.
internal enum Comparisons {
    /// A binary comparison over the visitor value and the rule's test value. Every operator
    /// conforms to this signature so it can be a value in the ``comparators`` dispatch table.
    /// `@Sendable` is required for the static ``comparators`` table to be concurrency-safe under
    /// Swift 6 strict concurrency — references to the static-func operators capture no state and
    /// so satisfy it without any actor isolation or suppression.
    private typealias Comparator = @Sendable (_ value: String?, _ testAgainst: String?) -> Bool

    /// Wire `matchType` → comparator. The three `equals` aliases (`equals`/`equalsNumber`/
    /// `matches`) and the two absence aliases (`not_exists`/`doesNotExist`) point at the same
    /// function, exactly as the JS source aliases them (JS 42-43, 173).
    private static let comparators: [String: Comparator] = [
        "equals": equals,
        "equalsNumber": equals,
        "matches": equals,
        "less": less,
        "lessEqual": lessEqual,
        "contains": contains,
        "isIn": isIn,
        "startsWith": startsWith,
        "endsWith": endsWith,
        "regexMatches": regexMatches,
        "exists": exists,
        "not_exists": notExists,
        "doesNotExist": notExists
    ]

    /// Evaluates one rule condition.
    ///
    /// - Parameters:
    ///   - matchType: The wire operator string (e.g. `"equals"`, `"contains"`, `"isIn"`).
    ///   - value: The visitor-side value being tested (the attribute), or `nil` when absent.
    ///   - testAgainst: The rule-defined value to compare against, or `nil`.
    ///   - negated: When `true`, the operator's boolean result is inverted.
    ///   - logger: Sink for the WARN emitted on an unknown `matchType`.
    /// - Returns: The (optionally negated) match result. An unknown operator returns `false`
    ///   (fail-closed) without negation applied.
    static func evaluate(
        matchType: String,
        value: String?,
        testAgainst: String?,
        negated: Bool,
        logger: Logger
    ) -> Bool {
        guard let comparator = comparators[matchType] else {
            logger.log(
                level: .warn,
                type: "Comparisons",
                method: "evaluate",
                message: "unknown operator '\(matchType)', returning false"
            )
            return false
        }
        return applyNegation(comparator(value, testAgainst), negated: negated)
    }

    // MARK: - Helpers

    /// Lower-cases a possibly-absent string, treating `nil` as the empty string. Shared by the
    /// case-insensitive operators (equals / contains / startsWith / endsWith) so the
    /// nil-coalesce-then-lowercase pair lives in one place rather than being copied per call.
    private static func normalized(_ value: String?) -> String {
        (value ?? "").lowercased()
    }

    /// Inverts `result` when `negated` is `true`. Applied only to real-operator results — the
    /// unknown-operator branch returns its fail-closed `false` directly (JS parity).
    private static func applyNegation(_ result: Bool, negated: Bool) -> Bool {
        negated ? !result : result
    }

    // MARK: - Operators

    /// Case-insensitive string equality (JS `equals`, also the `equalsNumber` / `matches` alias).
    private static func equals(_ value: String?, _ testAgainst: String?) -> Bool {
        normalized(value) == normalized(testAgainst)
    }

    /// Numeric `<` with a type-guard: a non-numeric operand on either side yields `false`.
    private static func less(_ value: String?, _ testAgainst: String?) -> Bool {
        guard let lhs = numeric(value), let rhs = numeric(testAgainst) else { return false }
        return lhs < rhs
    }

    /// Numeric `<=` with the same type-guard as ``less(_:_:)``.
    private static func lessEqual(_ value: String?, _ testAgainst: String?) -> Bool {
        guard let lhs = numeric(value), let rhs = numeric(testAgainst) else { return false }
        return lhs <= rhs
    }

    /// The JS `isNumeric` pattern (string-utils.ts:68-74): an optional leading `-`, then either
    /// comma-grouped thousands (`1,000`) or plain digits, an optional decimal tail; OR a bare `.5`.
    /// Pinned so the matcher REJECTS what JS rejects — scientific notation (`1e3`), hex (`0x10`),
    /// `Infinity`/`nan`, and leading-plus (`+5`) — which Swift's bare `Double()` would otherwise
    /// accept, silently diverging less/lessEqual from JS (bd-vh1). [Source: javascript-sdk
    /// string-utils.ts:68-74]
    private static let numericPattern = "^-?(?:(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d+)?|\\.\\d+)$"

    /// Parses `value` as a `Double` ONLY when it matches the JS-`isNumeric` shape, returning `nil`
    /// otherwise (the type-guard miss). Commas are stripped before `Double()` to match JS
    /// `toNumber`'s `replace(/,/g,'')` (string-utils.ts:81-91) so comma-grouped thousands (`1,000`)
    /// parse as `1000`. The `^…$`-anchored ``numericPattern`` is what makes Swift reject the same
    /// strings JS rejects; bare `Double()` alone would accept sci-notation / hex / `Infinity` /
    /// leading-plus and break less/lessEqual parity (bd-vh1).
    private static func numeric(_ value: String?) -> Double? {
        guard let value else { return nil }
        guard value.range(of: numericPattern, options: .regularExpression) != nil else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: ""))
    }

    /// Case-insensitive substring test. `value` is the haystack, `testAgainst` the needle; an
    /// empty / whitespace-only needle matches everything (JS 80-82).
    private static func contains(_ value: String?, _ testAgainst: String?) -> Bool {
        let haystack = normalized(value)
        let needle = normalized(testAgainst)
        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return haystack.contains(needle)
    }

    /// Pipe-delimited membership. Candidates (from `value`) are NOT lowercased; the allow-list
    /// (from `testAgainst`) IS lowercased (JS 95-108) — an intentional asymmetry.
    ///
    /// Splitting uses `components(separatedBy:)`, NOT `split(separator:)`, specifically to
    /// PRESERVE empty segments and so match JS `String.prototype.split` semantics
    /// (JS `comparisons.ts` line 96 `String(values).split(splitter)`, line 101
    /// `testAgainst.split(splitter)`). Swift's `split(separator:)` omits empty subsequences by
    /// default, so `"".split` → `[]` and `"a|b|".split` → `["a","b"]` — both diverge from JS,
    /// where `"".split("|")` → `[""]` and `"a|b|".split("|")` → `["a","b",""]`.
    /// `components(separatedBy:)` matches JS exactly for empty, leading, trailing, and
    /// middle-empty pipes. Pinned by the empty-segment vectors in ComparisonsTests.swift.
    ///
    /// A `nil` value (an ABSENT visitor key) returns false up front, to match JS
    /// `String(undefined).split('|')` = `["undefined"]`, which never matches the allow-list.
    /// This is distinct from an explicit EMPTY-STRING value: `""` is non-nil, so it still flows
    /// through `components(separatedBy:)` → `[""]` and CAN match an empty allow-list segment
    /// (e.g. `isIn("", "a|b|")` → true). Both cases are pinned by vectors in ComparisonsTests.swift.
    private static func isIn(_ value: String?, _ testAgainst: String?) -> Bool {
        guard let value else { return false }  // absent key → false (JS parity; see doc comment above)
        let candidates = value.components(separatedBy: "|")          // NOT lowercased (JS parity)
        let allowed = (testAgainst ?? "").lowercased().components(separatedBy: "|")
        return candidates.contains { allowed.contains($0) }
    }

    /// Case-insensitive prefix test (JS 122-128).
    private static func startsWith(_ value: String?, _ testAgainst: String?) -> Bool {
        normalized(value).hasPrefix(normalized(testAgainst))
    }

    /// Case-insensitive suffix test (JS 130-141).
    private static func endsWith(_ value: String?, _ testAgainst: String?) -> Bool {
        normalized(value).hasSuffix(normalized(testAgainst))
    }

    /// Case-insensitive regex test (JS `'i'` flag). A `nil` operand or an invalid pattern
    /// yields `false` — `try?` swallows the compile failure rather than crashing.
    private static func regexMatches(_ value: String?, _ pattern: String?) -> Bool {
        guard let value, let pattern else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    /// Presence test: a value exists only when it is non-nil AND non-empty (the empty string
    /// counts as absent, JS 159). The `testAgainst` argument is unused — present only to match
    /// the shared ``Comparator`` signature.
    private static func exists(_ value: String?, _ testAgainst: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }

    /// Absence test (JS `not_exists`, also the `doesNotExist` alias): the empty string and
    /// `nil` both count as absent (JS 168-169). The `testAgainst` argument is unused — present
    /// only to match the shared ``Comparator`` signature.
    private static func notExists(_ value: String?, _ testAgainst: String?) -> Bool {
        guard let value else { return true }
        return value.isEmpty
    }
}

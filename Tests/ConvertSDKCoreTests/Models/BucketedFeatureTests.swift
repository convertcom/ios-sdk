// Tests/ConvertSDKCoreTests/Models/BucketedFeatureTests.swift
// Unit tests for the `BucketedFeature` MODEL (Epic 4 / Story 1): the typed `variable(_:as:)`
// accessor over the five `FeatureVariable` cases (AC5–AC10), its nil-on-miss / nil-on-mismatch
// contract (AC11), the `disabled(key:)` degraded factory (AC12), and the `Equatable` / `Codable`
// conformances (AC4). The `FeatureManager` evaluation that PRODUCES `BucketedFeature`s is tested
// separately in `Experience/FeatureManagerTests.swift`.

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("BucketedFeature")
struct BucketedFeatureTests {
    // MARK: - Shared construction

    /// Builds a multi-variable `BucketedFeature` whose `status` is the only knob, so the
    /// Equatable/Codable tests don't re-spell the same `variables:` dictionary inline (keeps
    /// new-duplicated-lines density under the SonarQube gate). Carries one of each of the five
    /// variable cases so the Codable test forces every `FeatureVariable` branch through encode
    /// AND decode.
    static func makeFeature(status: FeatureStatus) -> BucketedFeature {
        BucketedFeature(
            id: "feat-1",
            key: "checkout-flow",
            status: status,
            variables: [
                "flag": .boolean(true),
                "label": .string("hello"),
                "limit": .integer(42),
                "ratio": .float(3.14),
                "payload": .json(Data("{\"k\":1}".utf8))
            ]
        )
    }

    // MARK: - Typed accessor matrix (parameterized — AC5–AC10)

    /// One accessor case: a variable name, the `FeatureVariable` stored under it, and a
    /// `@Sendable` predicate that calls the matching typed accessor and confirms it returns the
    /// expected value. The check is boxed in a thunk (the `ConvertValueTests` idiom) so a SINGLE
    /// parameterized body covers all five heterogeneous `T.Type` assertions without re-spelling
    /// the accessor ladder — and so the case stays `Sendable`, which swift-testing's `arguments:`
    /// requires. A named struct (not a tuple) keeps the `large_tuple` lint rule satisfied.
    struct AccessorCase: Sendable {
        let label: String
        let name: String
        let variable: FeatureVariable
        let check: @Sendable (BucketedFeature) -> Bool
    }

    static let accessorCases: [AccessorCase] = [
        AccessorCase(
            label: "bool-var → Bool.self",
            name: "bool-var",
            variable: .boolean(true),
            check: { $0.variable("bool-var", as: Bool.self) == true }
        ),
        AccessorCase(
            label: "str-var → String.self",
            name: "str-var",
            variable: .string("hello"),
            check: { $0.variable("str-var", as: String.self) == "hello" }
        ),
        AccessorCase(
            label: "int-var → Int.self",
            name: "int-var",
            variable: .integer(42),
            check: { $0.variable("int-var", as: Int.self) == 42 }
        ),
        AccessorCase(
            label: "float-var → Double.self",
            name: "float-var",
            variable: .float(3.14),
            check: { $0.variable("float-var", as: Double.self) == 3.14 }
        ),
        AccessorCase(
            label: "json-var → Data.self",
            name: "json-var",
            variable: .json(Data("{\"k\":1}".utf8)),
            check: { $0.variable("json-var", as: Data.self) == Data("{\"k\":1}".utf8) }
        )
    ]

    @Test("variable(_:as:) returns the typed value for each of the five variable cases", arguments: accessorCases)
    func typedAccessorMatrix(testCase: AccessorCase) {
        let feature = BucketedFeature(
            id: "f",
            key: "f",
            status: .enabled,
            variables: [testCase.name: testCase.variable]
        )
        #expect(
            testCase.check(feature),
            "\(testCase.label): typed accessor did not return the stored value"
        )
    }

    // MARK: - Accessor nil paths (AC11)

    @Test("variable(_:as:) returns nil on a type mismatch and on an unknown name")
    func accessorReturnsNilOnMismatchOrMiss() {
        let feature = BucketedFeature(
            id: "f",
            key: "f",
            status: .enabled,
            variables: ["bool-var": .boolean(true)]
        )
        // Type mismatch: the value is `.boolean`, requested as `Int`.
        #expect(feature.variable("bool-var", as: Int.self) == nil)
        // Unknown name: no such key in `variables`.
        #expect(feature.variable("absent", as: String.self) == nil)
    }

    // MARK: - disabled(key:) factory (AC12)

    @Test("disabled(key:) builds a disabled feature with an empty id and no variables")
    func disabledFactory() {
        let feature = BucketedFeature.disabled(key: "any")
        #expect(feature.status == .disabled)
        #expect(feature.variables.isEmpty)
        #expect(feature.key == "any")
        #expect(feature.id == "")
        #expect(feature.variable("any", as: Bool.self) == nil)
    }

    // MARK: - Equatable (AC4)

    @Test("BucketedFeature is Equatable across status, key, and all variable cases")
    func equatableHonoursValueAndStatus() {
        let enabledFeature = Self.makeFeature(status: .enabled)
        let sameFeature = Self.makeFeature(status: .enabled)
        let differingStatus = Self.makeFeature(status: .disabled)

        // Two identically-built values compare equal — forces `Equatable` on
        // `BucketedFeature`, `FeatureVariable` (the `variables` values), and `FeatureStatus`.
        #expect(enabledFeature == sameFeature)
        // A value differing only in `status` compares unequal.
        #expect(enabledFeature != differingStatus)
    }

    // MARK: - Codable (AC4)

    @Test("BucketedFeature round-trips through JSON encode/decode unchanged")
    func codableRoundTrips() throws {
        let original = Self.makeFeature(status: .enabled)
        // Internal Swift<->Swift symmetry: encode then decode and require value equality.
        // The wire shape is unconstrained here (no JS parity assertion) — only that
        // encode/decode is a faithful round-trip, which forces `Codable` on all three types.
        let data = try CodableTestHelpers.sortedKeysEncoder.encode(original)
        let decoded = try JSONDecoder().decode(BucketedFeature.self, from: data)
        #expect(decoded == original)
    }
}

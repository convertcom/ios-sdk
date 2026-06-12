// Tests/ConvertSDKCoreTests/Segments/SegmentsManagerTests.swift
// RED-phase contract for `SegmentsManager` (Epic 4 / Story 4, bd-3tq — AC1/AC2/AC8/AC9).
//
// `SegmentsManager` does NOT exist yet (Sources/ConvertSDKCore/Segments/SegmentsManager.swift is
// an empty `.gitkeep` directory), so this suite is EXPECTED to fail to COMPILE — the correct RED
// outcome. The GREEN-phase implementer MUST satisfy every contract asserted below.
//
// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
//   * `SegmentsManager(decisionStore:logger:)` — a `Sendable struct` wrapping a `DecisionStore`
//     plus a `Logger`.
//   * `setDefaultSegments(_:forVisitorKey:)` reads the current `Segments` from the store,
//     MERGE-overlays only the six non-custom string wire keys present in the dict
//     (country/browser/devices/source/campaign/visitorType), leaves unknown keys ignored, and
//     writes back. Keys NOT present in the dict are RETAINED (merge, not replace). `customSegments`
//     is never touched by this call.
//   * `setCustomSegments(_:forVisitorKey:)` APPENDS the given ids to the existing array
//     (`(existing ?? []) + ids`) and touches none of the other six fields.
//   * `currentSegments(forVisitorKey:)` delegates to the store.

import Foundation
import Testing
@testable import ConvertSDKCore

@Suite("SegmentsManager")
struct SegmentsManagerTests {
    // MARK: Shared fixtures & helpers (SonarQube 3% new-duplicated-lines gate)

    /// Single factory for the subject — one place builds `SegmentsManager`, so no test
    /// inline-constructs it (SonarQube CPD operates on tokens, not names). `logger` defaults to a
    /// fresh `MockLogger`; `decisionStore` is injected by the caller so each scenario owns its store.
    private func makeManager(
        decisionStore: DecisionStore,
        logger: MockLogger = MockLogger()
    ) -> SegmentsManager {
        SegmentsManager(decisionStore: decisionStore, logger: logger)
    }

    /// Zero-arg convenience: builds a fresh store-backed manager in one call, so the
    /// store-construction line is not copy-pasted into every scenario (SonarQube CPD).
    private func makeManager() -> SegmentsManager {
        makeManager(decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore()))
    }

    // MARK: setDefaultSegments — merge semantics (AC1)

    @Test("setDefaultSegments merges with existing map (AC1)")
    func setDefaultMergesWithExistingMap() async {
        let mgr = makeManager()

        await mgr.setDefaultSegments(["country": "US"], forVisitorKey: "k")
        await mgr.setDefaultSegments(["campaign": "summer"], forVisitorKey: "k")
        let segs = await mgr.currentSegments(forVisitorKey: "k")

        #expect(segs.country == "US")        // retained from the first call
        #expect(segs.campaign == "summer")   // added by the second call — both survive (merge)
    }

    // MARK: setCustomSegments — append semantics (AC2)

    @Test("setCustomSegments appends to existing array (AC2)")
    func setCustomAppendsToExistingArray() async {
        let mgr = makeManager()

        await mgr.setCustomSegments(["seg-1"], forVisitorKey: "k")
        await mgr.setCustomSegments(["seg-2", "seg-3"], forVisitorKey: "k")

        #expect(await mgr.currentSegments(forVisitorKey: "k").customSegments == ["seg-1", "seg-2", "seg-3"])
    }

    // MARK: setDefaultSegments — unknown keys ignored (AC9)

    @Test("setDefaultSegments silently ignores unknown keys (AC9)")
    func setDefaultIgnoresUnknownKeys() async {
        let mgr = makeManager()

        await mgr.setDefaultSegments(["country": "FR", "unknownKey": "val"], forVisitorKey: "k")

        // Unknown key neither crashed nor threw, and maps to no field; the known key still landed.
        #expect(await mgr.currentSegments(forVisitorKey: "k").country == "FR")
    }

    // MARK: setDefaultSegments — every string wire key maps (parameterized)

    /// One wire-key mapping case. A named struct (not a bare 3-tuple) keeps the `large_tuple`
    /// SwiftLint rule satisfied (its default is `error` at 3 members) and stays `Sendable` for
    /// swift-testing's `arguments:`. `keyPath` reads the field the wire key should populate.
    /// `customSegments` is `[String]?` (not `String?`), so it is deliberately excluded here —
    /// its non-interference is covered by ``setDefaultPreservesCustomAndViceVersa()`` below.
    struct StringWireKeyCase: Sendable {
        let wireKey: String
        let keyPath: KeyPath<Segments, String?> & Sendable
        let value: String
    }

    static let stringWireKeyCases: [StringWireKeyCase] = [
        StringWireKeyCase(wireKey: "country", keyPath: \Segments.country, value: "US"),
        StringWireKeyCase(wireKey: "browser", keyPath: \Segments.browser, value: "SF"),
        StringWireKeyCase(wireKey: "devices", keyPath: \Segments.devices, value: "IPH"),
        StringWireKeyCase(wireKey: "source", keyPath: \Segments.source, value: "direct"),
        StringWireKeyCase(wireKey: "campaign", keyPath: \Segments.campaign, value: "spring"),
        StringWireKeyCase(wireKey: "visitorType", keyPath: \Segments.visitorType, value: "new")
    ]

    @Test("setDefaultSegments maps each string wire key", arguments: stringWireKeyCases)
    func setDefaultMapsEachStringWireKey(testCase: StringWireKeyCase) async {
        let mgr = makeManager()

        await mgr.setDefaultSegments([testCase.wireKey: testCase.value], forVisitorKey: "k")
        let segs = await mgr.currentSegments(forVisitorKey: "k")

        #expect(
            segs[keyPath: testCase.keyPath] == testCase.value,
            "wire key \"\(testCase.wireKey)\" did not map to its Segments field"
        )
    }

    // MARK: Non-interference between the two setters (AC1 / AC2)

    @Test("setDefaultSegments preserves customSegments; setCustomSegments preserves the six (AC1/AC2 non-interference)")
    func setDefaultPreservesCustomAndViceVersa() async {
        let mgr = makeManager()

        await mgr.setCustomSegments(["c1"], forVisitorKey: "k")
        await mgr.setDefaultSegments(["country": "US"], forVisitorKey: "k")
        let segs = await mgr.currentSegments(forVisitorKey: "k")

        #expect(segs.customSegments == ["c1"])  // the default-segment write left customSegments intact
        #expect(segs.country == "US")           // and the custom-segment write did not block the six
    }
}

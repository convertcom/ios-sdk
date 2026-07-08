// Tests/ConvertSwiftSDKTests/ConvertContextSetPreviewTests.swift
//
// RED phase (qs-02 IOS-5 — `ConvertContext.setPreview` wiring). Spec:
// `_bmad-output/planning-artifacts/2026-06-09-convert-ios-sdk/qs-02-experiment-preview.md`,
// contract §2 "Preview input" / §3 "Precedence"; AC4 (forced decision) / AC7 (isolation).
//
// This suite is an INTEGRATION suite over the PUBLIC `ConvertContext` surface
// (`setPreview` / `runExperience` / `runExperiences`) plus `PreviewParam.parse` — it never
// reaches into `PreviewState`'s internal storage shape, so it is agnostic to WHICH internal
// algorithm GREEN picks (eager resolution at `setPreview` time vs. lazy resolution inside
// `runExperience`) as long as the observable contract holds.
//
// Reused from prior stories (read, not reimplemented — verify signatures before use):
//   * `PreviewParam.parse(_:) -> (experienceId, variationId)?` — IOS-2,
//     `Sources/ConvertSwiftSDKCore/Preview/PreviewParam.swift`.
//   * `PreviewDecision.forcedVariation(for:variationId:) -> Variation?` — IOS-3,
//     `Sources/ConvertSwiftSDKCore/Preview/PreviewDecision.swift`.
//   * `PreviewState` (an `actor` in the `ConvertSwiftSDK` platform target, NOT
//     `ConvertSwiftSDKCore`) — IOS-4, `Sources/ConvertSwiftSDK/PreviewState.swift`; its own
//     header already predicts IOS-5 will extend it to also hold the per-context preview
//     target, mirroring `TrackingState`'s "one actor, held by `let`" shape.
//
// ── New API surface this suite PINS (does not yet exist — GREEN adds it) ───────────────────
//   * `ConvertContext.setPreview(experienceId: String, variationId: String) async` — `Void`
//     return (mirrors the sibling `setDefaultSegments`/`setCustomSegments` async setters —
//     NOT a fluent `-> ConvertContext` chain like the Android reference, since Swift's
//     async/await makes fire-and-forget unnecessary and every other `ConvertContext` mutator
//     here is a bare `await` statement).
//   * `ConvertSwiftSDK`'s internal test-seam init gains `previewHTTPClient: (any
//     HTTPClient)? = nil` (mirrors the existing `configProvider`/`eventSink`/`secureStore`
//     injection precedent): `nil` (production) resolves the same real
//     `URLSessionHTTPClient(sdkVersion: SDKVersion.current)` the composition root already
//     builds for the MAIN config fetch; a test injects a `MockHTTPClient` to stub the
//     PER-CONTEXT `?exp=` preview fetch WITHOUT touching the main config's `configProvider`
//     seam (the two are separate `ConfigFetchService`/`ConfigProviding` instances — see
//     `PreviewStateTests.swift`'s header, which already documents that `ConvertContext` does
//     not own a `ConfigFetchService` today and that `createContext` must build a SECOND one).
//   * `ConvertSwiftSDK.createContext` builds that second `ConfigFetchService` (over
//     `previewHTTPClient`, a fresh `CoordinatedFileStore()`, `self.configuration`, and
//     `self.logger` — the EXACT shape `ConvertSwiftSDK.swift` lines ~319-324 already use for
//     the main path) and a fresh `PreviewState` over it, passed into a new `ConvertContext`
//     init parameter — one `PreviewState` PER CONTEXT (AC7 isolation).
//
// ── Transport double: MockHTTPClient (NOT URLProtocolStub) — deliberate, documented choice ──
// `PreviewStateTests.swift` (the IOS-4 suite exercising this SAME `fetchExperienceConfig`
// seam) explicitly chose `MockHTTPClient` over `URLProtocolStub` for this exact fetch path
// ("keeps the suite parallel-safe (no process-global `URLProtocolStub` registry, no
// `.serialized` nesting needed)"). This suite follows that closer, more specific precedent
// rather than the task brief's looser "(stubbed URLProtocol)" phrasing — a REAL
// `URLSessionHTTPClient` is not required here because no test in this file asserts on
// request-level details (headers, exact URL) of the preview fetch; only PREVIEW OF DECISION,
// not TRANSPORT PLUMBING, is under test. (`DebugTokenRedactionTests`/AC1-AC3, which DO assert
// transport/redaction details, are why `URLSessionHTTPClient` + `URLProtocolStub` exist as a
// house-style pattern — this suite's scope is narrower.)
//
// ── Ordering judgment call: preview check runs AFTER the config-snapshot guard ──────────────
// The task brief cites `ProjectConfig.fullExperience(forKey:)` (`ProjectConfig.swift:177-178`)
// as part of the resolution path, which requires an already-non-nil `config` snapshot — unlike
// the Android reference (`packages/sdk/.../ConvertContext.kt`, `resolvePreviewOverride`), which
// checks the preview override BEFORE its config-ready gate. This suite therefore does not
// assert (and does not require) that a preview can force a decision on a context whose SDK has
// NEVER loaded any config at all; every scenario here awaits `sdk.ready()` first. See the
// dispatching agent's final report for the full grounding citations on the join-key mechanism.
//
// Deliberately OUT OF SCOPE (qs-02 IOS-6, not this task): no assertion that preview enqueues
// no tracking events, no assertion that preview suppresses visitor-state writes, and no
// assertion that preview events ARE tracked either — AC6 zero-trace hardening is untouched.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("ConvertContext setPreview wiring (qs-02 IOS-5)")
@MainActor
struct ConvertContextSetPreviewTests {
    /// `account_id` / `project.id` shared by every MAIN config this suite builds — declared
    /// once so the envelope JSON and the sticky-decision storeKey computation
    /// (`"<accountId>-<projectId>-<visitorId>"`, the shape `ConvertContext.storeKey(for:)`
    /// computes) never re-spell them (SonarQube 3% new-duplicated-lines gate).
    private static let mainAccountId = "acc-preview"
    private static let mainProjectId = "proj-preview"

    // MARK: - Fixture builders (SonarQube new-code-duplication discipline)

    /// One experience-wire JSON fragment: `type:"a/b"`, no audiences/locations, with the given
    /// `status` (default `"active"`) and `variations` (each an `(id, key, traffic)` triple).
    /// Shared by every fixture this suite builds — CPD is token-based, so ONE fragment builder
    /// (not renamed locals per test) keeps the diff under the 3% gate.
    private static func previewExpFragment(
        id: String,
        key: String,
        status: String = "active",
        variations: [(id: String, key: String, traffic: Int)]
    ) -> String {
        let variationsJSON = variations.map {
            #"{"id":"\#($0.id)","key":"\#($0.key)","traffic_allocation":\#($0.traffic)}"#
        }.joined(separator: ",")
        let head = #"{"id":"\#(id)","key":"\#(key)","status":"\#(status)","type":"a/b","#
        return head + #""audiences":[],"locations":[],"variations":[\#(variationsJSON)]}"#
    }

    /// The MAIN config every SUT is built with — `experiences` fragments joined into ONE
    /// envelope under the shared ``mainAccountId``/``mainProjectId``, so a seeded sticky
    /// decision's storeKey is predictable. `throws` only on malformed JSON
    /// (`ProjectConfig.init(from:)` degrades per-field, so a well-formed fragment never throws).
    private static func makeMainConfig(experiences: [String] = []) throws -> ProjectConfig {
        let envelope = #"{"account_id":"\#(mainAccountId)","project":{"id":"\#(mainProjectId)"},"#
            + #""experiences":[\#(experiences.joined(separator: ","))]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// The RAW wire bytes a stubbed `?exp=` preview fetch returns — its OWN, independent
    /// `account_id`/`project.id` (irrelevant to `PreviewDecision`, which never reads them).
    /// Returned as `Data` (not pre-decoded): `MockHTTPClient` hands its canned response
    /// straight to the transport layer; the SDK's OWN `ConfigFetchService` decodes it.
    private static func previewFetchBody(experiences: [String]) -> Data {
        let envelope = #"{"account_id":"acc-fetched","project":{"id":"proj-fetched"},"#
            + #""experiences":[\#(experiences.joined(separator: ","))]}"#
        return Data(envelope.utf8)
    }

    /// A 200 `HTTPURLResponse` for `MockHTTPClient`'s canned response. The `url` is incidental
    /// (`ConfigFetchService` never inspects the response object, only the paired `Data`), so a
    /// stable throwaway URL is reused (mirrors `PreviewStateTests.stubResponse`).
    private static func okResponse() -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: FileManager.default.temporaryDirectory,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            preconditionFailure("HTTPURLResponse(statusCode:200) is non-failing for a valid URL")
        }
        return response
    }

    // MARK: - SUT factory

    /// Everything a test needs: the ready SDK, its injected log spy, and its canonical
    /// `DecisionStore` (for seeding a sticky decision directly — the Precedence test).
    private struct SUT {
        let sdk: ConvertSwiftSDK
        let logger: MockLogger
        let decisionStore: DecisionStore
    }

    /// Builds a READY, off-network SDK: `mainConfig` is served by a `MockConfigProvider` (the
    /// MAIN config load never touches the network), and the per-context `?exp=` preview fetch
    /// is served by a `MockHTTPClient` seeded with `previewFetchResponse`. `nil` (the default)
    /// means every preview fetch hits `MockHTTPClient`'s documented default —
    /// `URLError(.badServerResponse)` — which `ConfigFetchService.fetchExperienceConfig`
    /// degrades to `nil`; from `setPreview`'s perspective that is indistinguishable from a
    /// fetch that succeeded but found nothing, so it doubles for "the experience is
    /// unreachable" in the inert-on-bad-input tests. A FRESH in-memory `DecisionStore` over a
    /// `MockFileStore` isolates each SUT's sticky state (mirrors the injection precedent
    /// across every `ConvertContext*` suite — see `ConvertContextRunExperienceTests.makeReadySDK`).
    private func makeSUT(
        mainConfig: ProjectConfig,
        previewFetchResponse: Data? = nil
    ) async throws -> SUT {
        let logger = MockLogger()
        let decisionStore = DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        let httpClient = MockHTTPClient(response: previewFetchResponse.map { ($0, Self.okResponse()) })
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: mainConfig),
            logger: logger,
            decisionStore: decisionStore,
            previewHTTPClient: httpClient
        )
        try await sdk.ready()
        return SUT(sdk: sdk, logger: logger, decisionStore: decisionStore)
    }

    // MARK: - AC4: forced decision via the ?exp= fetch

    /// A DRAFT experience absent from the MAIN config, delivered ONLY via the stubbed `?exp=`
    /// preview fetch: after `setPreview`, running it BY KEY on the preview context returns the
    /// requested variation — bypassing its `draft` status and its zero-traffic-irrelevant
    /// variation weights entirely (`PreviewDecision.forcedVariation` never reads either).
    @Test("setPreview forces the variation for a draft experience delivered only via the ?exp= fetch (AC4)")
    func setPreviewForcesDraftExperienceViaExpFetch() async throws {
        let sut = try await makeSUT(
            mainConfig: try Self.makeMainConfig(),
            previewFetchResponse: Self.previewFetchBody(experiences: [
                Self.previewExpFragment(
                    id: "9001",
                    key: "preview-key",
                    status: "draft",
                    variations: [(id: "5001", key: "control", traffic: 50), (id: "5002", key: "variant", traffic: 50)]
                )
            ])
        )
        let context = sut.sdk.createContext(visitorId: "user-1")

        await context.setPreview(experienceId: "9001", variationId: "5002")
        let variation = await context.runExperience("preview-key")

        #expect(variation?.id == "5002")
        #expect(variation?.key == "variant")
        #expect(variation?.experienceKey == "preview-key")
    }

    // MARK: - Precedence (contract §3)

    /// `setPreview` beats a PRE-EXISTING sticky decision for the same experience on this
    /// context: the visitor already stickily bucketed into `"control"` (seeded directly via
    /// `DecisionStore.saveDecision`), yet after `setPreview` targets `"variant"`,
    /// `runExperience` returns `"variant"` — normal bucketing/stickiness never even considered.
    @Test("setPreview beats a persisted sticky decision for the same experience on this context")
    func setPreviewBeatsStickyDecision() async throws {
        let experienceId = "9002"
        let experienceKey = "precedence-key"
        let sut = try await makeSUT(mainConfig: try Self.makeMainConfig(experiences: [
            Self.previewExpFragment(
                id: experienceId,
                key: experienceKey,
                variations: [(id: "6001", key: "control", traffic: 100), (id: "6002", key: "variant", traffic: 0)]
            )
        ]))
        let context = sut.sdk.createContext(visitorId: "user-1")
        let storeKey = "\(Self.mainAccountId)-\(Self.mainProjectId)-user-1"
        await sut.decisionStore.saveDecision(variationId: "6001", experienceId: experienceId, storeKey: storeKey)

        await context.setPreview(experienceId: experienceId, variationId: "6002")
        let variation = await context.runExperience(experienceKey)

        #expect(variation?.id == "6002", "preview must beat the pre-existing sticky decision")
    }

    // MARK: - Inert on bad input

    /// An `experienceId` that resolves to NOTHING — absent from the local config AND absent
    /// after the `?exp=` fetch — is inert: a warning is logged, and this context then behaves
    /// FULLY NORMALLY for every experience (a sibling, unrelated experience still buckets its
    /// deterministic 100%-traffic variation).
    @Test("setPreview with an unknown experienceId logs a warning and falls through to normal decisions")
    func setPreviewUnknownExperienceIdIsInert() async throws {
        let normalKey = "normal-key"
        let normalVariationId = "7001"
        let sut = try await makeSUT(
            mainConfig: try Self.makeMainConfig(experiences: [
                Self.previewExpFragment(id: "8001", key: normalKey, variations: [(id: normalVariationId, key: "control", traffic: 100)])
            ]),
            previewFetchResponse: Self.previewFetchBody(experiences: [])
        )
        let context = sut.sdk.createContext(visitorId: "user-1")

        await context.setPreview(experienceId: "does-not-exist", variationId: "does-not-matter")

        #expect(sut.logger.entries().contains { $0.level == .warn }, "an unresolved preview target must log a warning")

        let variation = await context.runExperience(normalKey)
        #expect(variation?.id == normalVariationId, "an inert preview must not disturb an unrelated experience's decision")
    }

    /// A KNOWN `experienceId` but an unknown `variationId` (not present in that experience's
    /// `variations`, even after the resolve) is inert THE SAME WAY: a warning is logged, and
    /// running that experience by key returns its NORMAL decision, not a forced one.
    @Test("setPreview with a known experienceId but unknown variationId logs a warning and decides normally")
    func setPreviewUnknownVariationIdIsInert() async throws {
        let experienceId = "9003"
        let experienceKey = "known-key"
        let knownVariationId = "6101"
        let sut = try await makeSUT(mainConfig: try Self.makeMainConfig(experiences: [
            Self.previewExpFragment(id: experienceId, key: experienceKey, variations: [(id: knownVariationId, key: "control", traffic: 100)])
        ]))
        let context = sut.sdk.createContext(visitorId: "user-1")

        await context.setPreview(experienceId: experienceId, variationId: "does-not-exist-in-experience")

        #expect(sut.logger.entries().contains { $0.level == .warn }, "an unknown variationId must log a warning")

        let variation = await context.runExperience(experienceKey)
        #expect(variation?.id == knownVariationId, "an unknown variationId must fall through to the normal decision")
    }

    // MARK: - AC7: isolation

    /// A concurrent NON-preview context on the SAME SDK buckets, persists, and decides
    /// COMPLETELY normally: preview state lives ONLY on the per-context `PreviewState`, never
    /// on any shared `ConvertSwiftSDK`-level state, so a sibling context that never called
    /// `setPreview` is entirely unaffected by another context's active preview target.
    @Test("a concurrent non-preview context on the same SDK buckets normally (AC7 isolation)")
    func concurrentNonPreviewContextIsolated() async throws {
        let experienceId = "9004"
        let experienceKey = "iso-key"
        let normalVariationId = "6201"
        let forcedVariationId = "6202"
        let sut = try await makeSUT(mainConfig: try Self.makeMainConfig(experiences: [
            Self.previewExpFragment(
                id: experienceId,
                key: experienceKey,
                variations: [(id: normalVariationId, key: "control", traffic: 100), (id: forcedVariationId, key: "variant", traffic: 0)]
            )
        ]))

        let previewContext = sut.sdk.createContext(visitorId: "preview-visitor")
        await previewContext.setPreview(experienceId: experienceId, variationId: forcedVariationId)
        let forced = await previewContext.runExperience(experienceKey)
        #expect(forced?.id == forcedVariationId, "the preview context itself must still force")

        let otherContext = sut.sdk.createContext(visitorId: "other-visitor")
        let normal = await otherContext.runExperience(experienceKey)
        #expect(normal?.id == normalVariationId, "a context that never called setPreview must bucket normally")
    }

    // MARK: - runExperiences: only the target is forced

    /// `runExperiences()` forces ONLY the previewed experience; a sibling, non-previewed
    /// experience in the SAME bulk call still decides normally (contract §2: "other
    /// experiences still evaluate and decide normally for coherent rendering").
    @Test("runExperiences forces only the previewed experience; siblings still decide normally")
    func setPreviewForcesOnlyTargetInRunExperiences() async throws {
        let targetId = "9005"
        let targetKey = "key-b"
        let siblingKey = "key-a"
        let siblingVariationId = "6301"
        let normalTargetVariationId = "6401"
        let forcedTargetVariationId = "6402"
        let sut = try await makeSUT(mainConfig: try Self.makeMainConfig(experiences: [
            Self.previewExpFragment(id: "9099", key: siblingKey, variations: [(id: siblingVariationId, key: "control", traffic: 100)]),
            Self.previewExpFragment(
                id: targetId,
                key: targetKey,
                variations: [
                    (id: normalTargetVariationId, key: "control", traffic: 100),
                    (id: forcedTargetVariationId, key: "variant", traffic: 0)
                ]
            )
        ]))
        let context = sut.sdk.createContext(visitorId: "user-1")

        await context.setPreview(experienceId: targetId, variationId: forcedTargetVariationId)
        let results = await context.runExperiences()

        let sibling = results.first { $0.experienceKey == siblingKey }
        let target = results.first { $0.experienceKey == targetKey }
        #expect(sibling?.id == siblingVariationId, "a non-previewed sibling experience must still decide normally")
        #expect(target?.id == forcedTargetVariationId, "the previewed experience must be forced")
    }

    // MARK: - Wiring from PreviewParam

    /// The intended host entrypoint end-to-end: `PreviewParam.parse` extracts the
    /// `(experienceId, variationId)` pair from the canonical `"{expId}.{varId}"` link value,
    /// and feeding that pair straight into `setPreview` forces the requested variation.
    @Test("PreviewParam.parse feeds setPreview end-to-end")
    func parsePreviewParamThenSetPreviewForces() async throws {
        let sut = try await makeSUT(
            mainConfig: try Self.makeMainConfig(),
            previewFetchResponse: Self.previewFetchBody(experiences: [
                Self.previewExpFragment(
                    id: "9006",
                    key: "link-key",
                    variations: [(id: "6501", key: "control", traffic: 100), (id: "6502", key: "variant", traffic: 0)]
                )
            ])
        )
        let context = sut.sdk.createContext(visitorId: "user-1")

        let parsed = try #require(PreviewParam.parse("9006.6502"))
        await context.setPreview(experienceId: parsed.experienceId, variationId: parsed.variationId)
        let variation = await context.runExperience("link-key")

        #expect(variation?.id == "6502")
    }
}

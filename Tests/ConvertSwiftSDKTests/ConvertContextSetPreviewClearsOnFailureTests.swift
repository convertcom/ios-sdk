// Tests/ConvertSwiftSDKTests/ConvertContextSetPreviewClearsOnFailureTests.swift
//
// JS parity fix (fullstack-v12): the JS reference nulls its `_preview` field on EVERY
// `setPreview` failure path — `ConvertContext.setPreview(experienceId:variationId:)`'s
// inert-on-bad-input guard (`Sources/ConvertSwiftSDK/ConvertContext.swift`) previously left a
// PRIOR successful preview target untouched on a subsequent FAILED resolution, so a stale forced
// decision from an earlier `setPreview` call could survive indefinitely. GREEN now clears
// `PreviewState.forcedVariation` (via `PreviewState.clearForcedVariation()`) on that same guard.
//
// Lives in its OWN file (mirroring `PreviewFeatureZeroTraceTests.swift`'s documented precedent of
// each `ConvertContext*`/`Preview*` suite owning its own self-contained SUT construction rather
// than widening a sibling file's `private` access) — keeps `ConvertContextSetPreviewTests.swift`
// under SwiftLint's `file_length` gate rather than growing it past 400 lines.
import Testing
import Foundation
@testable import ConvertSwiftSDK

@Suite("ConvertContext setPreview clears a prior target on a failed re-preview (JS parity)")
@MainActor
struct SetPreviewClearsOnFailureTests {
    private static let accountId = "acc-preview-clear"
    private static let projectId = "proj-preview-clear"

    /// One experience carrying a 100%-traffic control and a 0%-traffic variant — mirrors
    /// `ConvertContextSetPreviewTests.previewExpFragment`'s shape (own copy per the file-header
    /// precedent above).
    private static func makeConfig(experienceId: String, key: String) throws -> ProjectConfig {
        let variations = #"[{"id":"normal","key":"control","traffic_allocation":100},"#
            + #"{"id":"forced","key":"variant","traffic_allocation":0}]"#
        let experience = #"{"id":"\#(experienceId)","key":"\#(key)","type":"a/b","#
            + #""audiences":[],"locations":[],"variations":\#(variations)}"#
        let ids = #""account_id":"\#(accountId)","project":{"id":"\#(projectId)"}"#
        let envelope = #"{\#(ids),"experiences":[\#(experience)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// A READY SDK over an off-network `MockConfigProvider` — the failing re-preview's
    /// `experienceId` is absent from this config, so its `?exp=` fallback fetch is exercised too;
    /// the default (no injected `previewHTTPClient`) `MockHTTPClient`-backed seam is not used here
    /// since `ConvertSwiftSDK`'s test-seam init requires an explicit stub to avoid a real network
    /// call, mirroring `ConvertContextSetPreviewTests.makeSUT`'s `previewHTTPClient` injection.
    private func makeReadySDK(experienceId: String, key: String) async throws -> ConvertSwiftSDK {
        let config = try Self.makeConfig(experienceId: experienceId, key: key)
        let sdk = ConvertSwiftSDK(
            configuration: ConvertConfiguration(sdkKey: "preview-clear-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: config),
            logger: NoopLogger(),
            previewHTTPClient: MockHTTPClient()
        )
        try await sdk.ready()
        return sdk
    }

    /// JS parity: a FAILED re-preview (an unresolvable `experienceId`) must clear a PRIOR
    /// successful preview target rather than leave it stuck — the same experience must decide its
    /// NORMAL (100%-allocation) variation afterward, not stay forced to the earlier target.
    @Test("a failed re-preview clears a prior successful preview target")
    func failedRePreviewClearsPriorForcedVariation() async throws {
        let experienceId = "9501"
        let key = "clears-key"
        let sdk = try await makeReadySDK(experienceId: experienceId, key: key)
        let context = sdk.createContext(visitorId: "user-1")

        await context.setPreview(experienceId: experienceId, variationId: "forced")
        let forced = await context.runExperience(key)
        #expect(forced?.id == "forced", "the first, successful setPreview must still force")

        await context.setPreview(experienceId: "does-not-exist", variationId: "does-not-matter")
        let afterFailedRePreview = await context.runExperience(key)
        #expect(afterFailedRePreview?.id == "normal", "a failed re-preview must clear the prior forced target")
    }
}

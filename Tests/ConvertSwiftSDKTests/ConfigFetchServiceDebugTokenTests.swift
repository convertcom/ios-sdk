// Tests/ConvertSwiftSDKTests/ConfigFetchServiceDebugTokenTests.swift
//
// RED phase (qs-02 IOS-1, AC1/AC2 — debugToken transport + cache elimination). Split out of
// `ConfigFetchServiceTests.swift` as an `extension ConfigFetchServiceTests` (same module, same
// suite) purely to keep that file and its `type_body_length` under the project's SwiftLint
// limits — this is NOT a separate suite; swift-testing discovers `@Test` methods on a type across
// extensions in the same module, so these run as part of the `"ConfigFetchService"` `@Suite`.
// Reuses `ConfigFetchServiceTests`'s `makeSUT` / `SUT` / shared constants verbatim (both widened
// from `private` to internal there) rather than duplicating the wiring (SonarQube new-code
// duplication discipline).
//
// This file fails to compile until `ConvertConfiguration.debugToken` exists (GREEN, qs-02 IOS-1)
// — the same RED signal `ConfigFetchServiceTests.swift` now carries via its `makeSUT` call.
import Testing
import Foundation
@testable import ConvertSwiftSDK

extension ConfigFetchServiceTests {
    // MARK: - debugToken transport (qs-02 IOS-1, AC1)

    /// `buildConfigURL()` debugToken transport matrix (qs-02 IOS-1, AC1): when `debugToken` is
    /// set, the URL carries `debug_token=<value>` AND `_conv_low_cache=1` is FORCED regardless of
    /// `networkCacheLevel`; when unset, `_conv_low_cache=1` follows `networkCacheLevel` exactly as
    /// today. Asserted via query-item COUNTS (`.filter { }.count`), NOT
    /// `Dictionary(uniqueKeysWithValues:)` — the sibling `buildConfigURLAppendsQueryItems` test uses
    /// that helper, but on a genuine duplicate-key defect (e.g. `_conv_low_cache` emitted twice when
    /// `debugToken` is set AND `networkCacheLevel == .low`) `Dictionary(uniqueKeysWithValues:)` would
    /// `fatalError` the whole test process rather than fail one test — precisely the dedup defect
    /// this table exists to catch safely. A SEPARATE test from `buildConfigURLAppendsQueryItems` for
    /// that reason (not an extension of its existing table).
    @Test(
        "buildConfigURL debugToken transport: appends debug_token and forces/dedupes _conv_low_cache",
        arguments: [
            (
                debugToken: String?.none,
                cacheLevel: CacheLevel.normal,
                expectedLowCacheCount: 0,
                expectDebugToken: false
            ),
            (
                debugToken: String?.none,
                cacheLevel: .low,
                expectedLowCacheCount: 1,
                expectDebugToken: false
            ),
            (
                debugToken: "qa-token",
                cacheLevel: .normal,
                expectedLowCacheCount: 1,
                expectDebugToken: true
            ),
            (
                debugToken: "qa-token",
                cacheLevel: .low,
                expectedLowCacheCount: 1,
                expectDebugToken: true
            )
        ]
    )
    func buildConfigURLDebugTokenTransport(
        debugToken: String?,
        cacheLevel: CacheLevel,
        expectedLowCacheCount: Int,
        expectDebugToken: Bool
    ) throws {
        let sut = makeSUT(cacheLevel: cacheLevel, debugToken: debugToken)

        let url = try sut.service.buildConfigURL()

        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "built URL is not decomposable into URLComponents"
        )
        let queryItems = components.queryItems ?? []
        let lowCacheCount = queryItems.filter { $0.name == "_conv_low_cache" }.count
        let debugTokenItems = queryItems.filter { $0.name == "debug_token" }
        #expect(lowCacheCount == expectedLowCacheCount)
        if expectDebugToken {
            #expect(debugTokenItems.count == 1)
            #expect(debugTokenItems.first?.value == debugToken)
        } else {
            #expect(debugTokenItems.isEmpty)
        }
    }

    /// AC1 wire proof — ALSO the complete coverage of the "scheduler refresh" clause of AC1.
    /// `ConfigRefreshScheduler.performRefresh()` (`Sources/ConvertSwiftSDK/Lifecycle/
    /// ConfigRefreshScheduler.swift`, lines ~296-309) calls `fetchService.fetchLiveConfig()`
    /// VERBATIM, with zero scheduler-specific branching. `ConvertSwiftSDK.swift` (lines ~319-367)
    /// builds exactly ONE `ConfigFetchService` instance (`activeProvider`) and passes that SAME
    /// instance to BOTH the initial fetch and the `ConfigRefreshScheduler`. There is no second
    /// URL-building code path a scheduler refresh could exercise that this seam does not already
    /// cover, so this ONE `fetchLiveConfig()` proof at the `ConfigFetchService` level IS the
    /// complete coverage of "both the initial fetch and a scheduler refresh" — mirroring the
    /// precedent `Tests/ConvertSwiftSDKTests/Integration/FullChainIntegrationTests.swift` (its
    /// "AC1 REINTERPRETED" header) already set for a different story that hit the same
    /// no-second-seam wall.
    @Test("fetchLiveConfig issues a GET whose URL carries debug_token and exactly one _conv_low_cache")
    func fetchLiveConfigRequestCarriesDebugTokenAndLowCache() async throws {
        let sut = makeSUT(cacheLevel: .normal, httpResponse: Self.validConfigJSON, debugToken: "qa-token")

        _ = await sut.service.fetchLiveConfig()

        let requests = await sut.httpClient.requests
        let request = try #require(requests.first, "the service issued no request to the transport")
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            "built URL is not decomposable into URLComponents"
        )
        let queryItems = components.queryItems ?? []
        #expect(queryItems.filter { $0.name == "debug_token" }.first?.value == "qa-token")
        #expect(queryItems.filter { $0.name == "_conv_low_cache" }.count == 1)
    }

    // MARK: - AC2: cache elimination

    /// AC2 (post-fetch write elimination, qs-02 IOS-1). With `debugToken` set,
    /// `fetchLiveConfig()` must NOT write-through the response bytes to the disk cache at all —
    /// the QA config must never persist. Table-driven over the boolean so the shared fetch +
    /// read-back logic lives once (SonarQube new-code-duplication discipline): the `debugToken:
    /// nil` case is a regression lock on the existing write-through contract (mirrors
    /// `fetchLiveConfigWritesRawBytesToCache` in the sibling file), and the `debugToken` case
    /// proves the skip by asserting the follow-up read THROWS (no file was ever created at
    /// `cacheURL`).
    @Test(
        "fetchLiveConfig skips the disk write entirely when debugToken is set",
        arguments: [
            (debugToken: String?.none, expectWrite: true),
            (debugToken: "qa-token", expectWrite: false)
        ]
    )
    func fetchLiveConfigDebugTokenEliminatesWrite(
        debugToken: String?,
        expectWrite: Bool
    ) async throws {
        let sut = makeSUT(httpResponse: Self.validConfigJSON, debugToken: debugToken)

        let config = await sut.service.fetchLiveConfig()

        #expect(config != nil)
        if expectWrite {
            let onDisk = try await sut.fileStore.read(from: sut.cacheURL)
            #expect(onDisk == Self.validConfigJSON)
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await sut.fileStore.read(from: sut.cacheURL)
            }
        }
    }

    /// AC2 (cold-start read elimination, qs-02 IOS-1). With `debugToken` set,
    /// `loadCachedConfig()` must NOT read the on-disk cache at all — the on-disk file is
    /// pre-seeded with a KNOWN-VALID config (proving a real read would succeed), so a `nil`
    /// result with `debugToken` set proves the read was skipped rather than merely failing.
    ///
    /// ── MockFileStore-vs-concrete-type discrepancy (verified) ────────────────────────────
    /// `ConfigFetchService.fileStore` is typed as the CONCRETE `CoordinatedFileStore` actor, not
    /// `any FileStore` — so the protocol-conforming `MockFileStore` (`Support/MockPorts.swift`)
    /// cannot be injected here. This test uses the same real-`CoordinatedFileStore` + unique-temp-
    /// `cacheURL` approach `makeSUT` already wires for every other case in this suite; no new test
    /// infrastructure is introduced.
    @Test(
        "loadCachedConfig skips the disk read entirely when debugToken is set",
        arguments: [
            (debugToken: String?.none, expectCachedValueReturned: true),
            (debugToken: "qa-token", expectCachedValueReturned: false)
        ]
    )
    func loadCachedConfigDebugTokenEliminatesRead(
        debugToken: String?,
        expectCachedValueReturned: Bool
    ) async throws {
        let sut = makeSUT(debugToken: debugToken)
        try await sut.fileStore.write(Self.validConfigJSON, to: sut.cacheURL)

        let config = await sut.service.loadCachedConfig()

        if expectCachedValueReturned {
            let decoded = try #require(
                config,
                "a pre-seeded valid cache file must decode to a non-nil config when debugToken is unset"
            )
            #expect(decoded.accountId == Self.validAccountId)
        } else {
            #expect(config == nil)
        }
    }
}

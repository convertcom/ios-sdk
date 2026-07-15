// Tests/ConvertSwiftSDKTests/ConfigFetchServiceExperienceTests.swift
//
// RED phase (qs-02 IOS-4, AC8 — the `?exp=` fetch variant). Split out of
// `ConfigFetchServiceTests.swift` as an `extension ConfigFetchServiceTests` (same module, same
// suite) purely to keep that file and its `type_body_length` under the project's SwiftLint
// limits — this is NOT a separate suite; swift-testing discovers `@Test` methods on a type
// across extensions in the same module, so these run as part of the `"ConfigFetchService"`
// `@Suite`. Reuses `ConfigFetchServiceTests`'s `makeSUT` / `SUT` / shared constants verbatim
// (both already widened to internal for the sibling `ConfigFetchServiceDebugTokenTests.swift`)
// rather than duplicating the wiring (SonarQube new-code-duplication discipline).
//
// This file fails to compile until `ConfigFetchService.buildExperienceConfigURL(experienceId:)`
// and `ConfigFetchService.fetchExperienceConfig(experienceId:)` exist (GREEN, qs-02 IOS-4) — the
// same RED signal the sibling debug-token file carried for IOS-1.
//
// ── Contract under test (qs-02 §2 "Resolution") ────────────────────────────────────────────
// The exp-fetch variant builds the config URL with `exp={experienceId}` appended, FORCES
// `_conv_low_cache=1` unconditionally (independent of `networkCacheLevel` — mirroring how a
// `debugToken` forces it on the normal path), and appends `debug_token=<value>` when configured
// (reusing the IOS-1 logic). It must NEVER write-through to the on-disk config cache — the
// existing write-skip-when-`debugToken != nil` (IOS-1, `ConfigFetchService.swift:254`) is
// WIDENED on this path to apply UNCONDITIONALLY, regardless of whether `debugToken` is set,
// because a preview fetch must never persist a QA/stakeholder-only config as the ordinary
// cached config for subsequent launches.
import Testing
import Foundation
@testable import ConvertSwiftSDK

extension ConfigFetchServiceTests {
    // MARK: - buildExperienceConfigURL: query-item shape (qs-02 IOS-4)

    /// `buildExperienceConfigURL(experienceId:)` query-item matrix: `exp={id}` is always
    /// present exactly once, `_conv_low_cache=1` is FORCED exactly once regardless of
    /// `networkCacheLevel` (the exp path never consults it — unlike `buildConfigURL`, which
    /// only forces it when a `debugToken` is set OR `networkCacheLevel == .low`), and
    /// `debug_token={value}` is present iff a `debugToken` is configured. Parameterized over
    /// the four `debugToken` × `cacheLevel` combinations so the build-and-inspect logic lives
    /// once (SonarQube new-code-duplication discipline) instead of four near-identical bodies.
    @Test(
        "buildExperienceConfigURL appends exp + forced _conv_low_cache + debug_token when configured",
        arguments: [
            (debugToken: String?.none, cacheLevel: CacheLevel.normal, expectDebugToken: false),
            (debugToken: String?.none, cacheLevel: .low, expectDebugToken: false),
            (debugToken: "qa-token", cacheLevel: .normal, expectDebugToken: true),
            (debugToken: "qa-token", cacheLevel: .low, expectDebugToken: true)
        ]
    )
    func buildExperienceConfigURLAppendsQueryItems(
        debugToken: String?,
        cacheLevel: CacheLevel,
        expectDebugToken: Bool
    ) throws {
        let sut = makeSUT(cacheLevel: cacheLevel, debugToken: debugToken)

        let url = try sut.service.buildExperienceConfigURL(experienceId: "555")

        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "built URL is not decomposable into URLComponents"
        )
        let queryItems = components.queryItems ?? []
        let expItems = queryItems.filter { $0.name == "exp" }
        let lowCacheItems = queryItems.filter { $0.name == "_conv_low_cache" }
        #expect(expItems.count == 1)
        #expect(expItems.first?.value == "555")
        // FORCED exactly once on every combination — the exp path never consults cacheLevel.
        #expect(lowCacheItems.count == 1)
        let debugTokenItems = queryItems.filter { $0.name == "debug_token" }
        if expectDebugToken {
            #expect(debugTokenItems.count == 1)
            #expect(debugTokenItems.first?.value == debugToken)
        } else {
            #expect(debugTokenItems.isEmpty)
        }
    }

    // MARK: - fetchExperienceConfig: decode + request shape

    /// `fetchExperienceConfig(experienceId:)` decodes a valid response into a `ProjectConfig`
    /// AND the GET it issued to the transport carries `exp={id}` plus exactly one
    /// `_conv_low_cache=1` — proving the built URL from `buildExperienceConfigURLAppendsQueryItems`
    /// above is the one actually sent, not merely constructible.
    @Test("fetchExperienceConfig decodes a valid response and issues a GET whose URL carries exp={id}")
    func fetchExperienceConfigDecodesAndCarriesExpParam() async throws {
        let sut = makeSUT(httpResponse: Self.validConfigJSON)

        let config = await sut.service.fetchExperienceConfig(experienceId: "777")

        let decoded = try #require(config, "a valid response must decode to a non-nil config")
        #expect(decoded.accountId == Self.validAccountId)
        let requests = await sut.httpClient.requests
        let request = try #require(requests.first, "the service issued no request to the transport")
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            "built URL is not decomposable into URLComponents"
        )
        let queryItems = components.queryItems ?? []
        #expect(queryItems.filter { $0.name == "exp" }.first?.value == "777")
        #expect(queryItems.filter { $0.name == "_conv_low_cache" }.count == 1)
    }

    // MARK: - fetchExperienceConfig: cache-write elimination (widened IOS-1 skip)

    /// The widened write-skip: `fetchExperienceConfig` NEVER writes the response to the disk
    /// cache — even when `debugToken == nil` (unlike the ordinary `fetchLiveConfig` path, whose
    /// write-skip today is conditioned on `debugToken != nil`). Table-driven over `debugToken`
    /// so the shared fetch + read-back-must-throw assertion lives once (SonarQube new-code-
    /// duplication discipline); `expectWrite` is always `false` on THIS path for both cases —
    /// the parameterization exists to prove the `debugToken == nil` case is not an accidental
    /// pass-through of the ordinary write-through contract.
    @Test(
        "fetchExperienceConfig never writes to the disk cache, regardless of debugToken",
        arguments: [String?.none, "qa-token"]
    )
    func fetchExperienceConfigNeverWritesToDiskCache(debugToken: String?) async throws {
        let sut = makeSUT(httpResponse: Self.validConfigJSON, debugToken: debugToken)

        let config = await sut.service.fetchExperienceConfig(experienceId: "888")

        #expect(config != nil, "a valid response must still decode even though it is never cached")
        await #expect(throws: (any Error).self) {
            _ = try await sut.fileStore.read(from: sut.cacheURL)
        }
    }
}

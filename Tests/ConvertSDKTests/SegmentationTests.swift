// Tests/ConvertSDKTests/SegmentationTests.swift
// `@testable import ConvertSDK` (the established cross-target pattern — see `ConversionTrackingTests.swift`
// / `GoalDeduplicationTests.swift` headers): this suite reaches the SDK's INTERNAL surface so the separate
// test target can see `internal` members. It lives in its OWN dedicated behavioral file (the Story 4.3
// convention — `GoalDeduplicationTests`, `ConversionTrackingTests` — NOT appended to `ConvertContextTests`)
// so neither file trips SwiftLint's `file_length` (400) limit.
//
// ── Story 4.4 (Epic 4) — visitor segmentation public API (bd-5qq, AC1/AC2/AC11/AC12) RED phase ──────────
// Asserts the REAL behaviour the GREEN step must produce when it replaces the two SYNC NO-OP STUBS on
// `ConvertContext` (`setDefaultSegments(_:)` / `setCustomSegments(_:)`, see `ConvertContext.swift` ~410-419)
// with `async` methods that delegate to a `SegmentsManager`, fire `SystemEvent.segments` once via the
// `EventBus`, and overlay the visitor's segments into the audience-rule attribute map `runExperience`
// evaluates against. The contract GREEN implements:
//   * `setDefaultSegments([String: String])` / `setCustomSegments([String])` are `async`; each records the
//     visitor's segments and fires `SystemEvent.segments` EXACTLY ONCE with a `SegmentsPayload` (AC12);
//   * a segment set via `setDefaultSegments` feeds the audience evaluation — an experience gated on
//     `country == "US"` buckets for a visitor whose `country` segment is `"US"`, and does NOT bucket for a
//     visitor that set no such segment (AC11).
//
// ── Why these tests are RED today ────────────────────────────────────────────────────────────────────
// The stub `setDefaultSegments(_:)` takes `Segments` (NOT `[String: String]`) and is SYNCHRONOUS, so the
// call sites here (`await context.setDefaultSegments(["country": "US"])`) FAIL TO COMPILE on BOTH the
// argument type (`[String: String]` vs `Segments`) and the `await` (the stub is not `async`) — that
// compile-fail IS the RED signal for the missing GREEN seam. Even if the signature compiled, the behaviour
// tests would FAIL at runtime because the stub is a NO-OP: it fires no `.segments` event (fireCount stays 0)
// and records no segments, so the AC11 audience-gated positive case never buckets (`country` never reaches
// the gate) — `variation == nil` where the test expects non-nil.
//
// ── The audience-gated fixture (AC11) ────────────────────────────────────────────────────────────────
// The SDK-target `Support/TestFixtures.swift` has NO audience-gated builder (every builder there ships
// `"audiences":[]`). The proven audience wire shape lives in the CORE target's
// `ProjectConfigFixtures.audienceJSON` / `.countryGatedExperienceConfig`, which compile into the OTHER
// target and are invisible across the boundary — so `makeCountryGatedConfig` REPLICATES that exact wire
// shape here (the established cross-boundary pattern this target already uses for `makeGoalConfig` etc.).
// `ConfigAudience.rules` is an allOf wrapper whose inner `RuleObjectAudience` decodes from the SAME object,
// so on the wire the `rules` value IS the rule graph directly: `{"OR":[{"AND":[{"OR_WHEN":[ <leaf> ]}]}]}`.
// The `{"rule_type":"country","value":"US","matching":{"match_type":"equals"}}` leaf is the one
// `RuleAdapterTests` proves decodes end-to-end through `RuleManager` + `Comparisons` (the `country`/`equals`
// operator is live in `Comparisons.comparators`).
//
// ── SonarQube 3% new-duplicated-lines gate ───────────────────────────────────────────────────────────
// SDK construction + `ready()` is built ONCE in `makeReadySDK(config:)` (the SOLE factory; it takes the
// config so the AC12 default-config cases and the AC11 audience-gated case share one construction site).
// The audience-gated wire JSON is assembled ONCE in `makeCountryGatedConfig`. The subscribe-and-count
// wiring is the shared `countSegments(on:)` helper, and the payload-capture wiring is the shared
// `captureSegments(on:)` helper — no `@Test` re-inlines SDK construction, the `.on(.segments)` block, or the
// audience wire literal (CPD is token-based — shared helpers, not renamed locals, hold the diff under the
// gate).
import Testing
import Foundation
@testable import ConvertSDK

// MARK: - Segmentation suite (Story 4.4)

@Suite("Segmentation")
@MainActor
struct SegmentationTests {
    /// The experience key the AC11 audience-gated cases bucket through — declared once so the fixture
    /// build and the `runExperience(_:)` call never re-spell the literal (SonarQube 3% gate).
    private static let experienceKey = "exp-key"
    /// The country the AC11 audience leaf gates on AND the segment value the positive case sets — one
    /// owner so the gate and the satisfying segment can never drift apart.
    private static let gatedCountry = "US"
    /// The `key` of the sole feature the AC11/parity feature fixture carries — declared once so the
    /// fixture build and the `runFeature(_:)` lookup never re-spell the literal (SonarQube 3% gate).
    /// Matches `makeFeatureConfig`'s default feature key so the spliced fixture reuses that wire shape
    /// verbatim (the feature `id`/change `feature_id` binding stays whatever `makeFeatureConfig` bakes).
    private static let featureKey = "flag-1"

    /// The fully-wired segmentation system-under-test plus the collaborator a test observes. A named
    /// struct (not a large tuple) keeps the `large_tuple` lint rule satisfied. `Sendable` — `ConvertSDK`
    /// is `Sendable` and `MockEventSink` is an `actor`.
    private struct SegmentationSUT: Sendable {
        /// The system under test — built ready over the supplied config, with the injected sink wired in.
        let sdk: ConvertSDK
        /// The sink a future segments enqueue would land in; held for parity with the sibling suites'
        /// SUTs (the `.segments` assertions read the bus via a counter/capture, not the sink).
        let sink: MockEventSink
    }

    /// Builds a READY off-network SDK over the SUPPLIED `config`, with an injected `MockEventSink`, then
    /// awaits `ready()` so `createContext().runExperience(...)` sees a NON-`nil` snapshot. The SOLE
    /// construction site, parameterized on the config so the AC12 default-config cases (a minimal goal-less
    /// config) and the AC11 audience-gated case share ONE `ConvertSDK(...)` + `ready()` build (SonarQube 3%
    /// gate). Mirrors `GoalDeduplicationTests.makeReadySDK` / `ConversionTrackingTests.makeReadySDK`: a
    /// `MockConfigProvider.ungated(cached: nil, live: config)` keeps the SDK off the network and resolves
    /// `ready()` non-degraded with that snapshot.
    private func makeReadySDK(config: ProjectConfig) async throws -> SegmentationSUT {
        let sink = MockEventSink()
        let sdk = ConvertSDK(
            configuration: ConvertConfiguration(sdkKey: "test-key"),
            configProvider: MockConfigProvider.ungated(cached: nil, live: config),
            eventSink: sink,
            logger: MockLogger(),
            decisionStore: DecisionStore(logger: MockLogger(), fileStore: MockFileStore())
        )
        try await sdk.ready()
        return SegmentationSUT(sdk: sdk, sink: sink)
    }

    /// A minimal valid `ProjectConfig` (account/project ids, no experiences/audiences) — all the AC12
    /// `.segments`-fire tests need is a ready SDK whose `createContext` works; they assert the bus signal,
    /// not bucketing. Decoded via the runtime `JSONDecoder` exactly as the `Support/TestFixtures.swift`
    /// builders do (`ProjectConfig.init(from:)` degrades per-field, so this shape never throws). Single
    /// owner of this envelope literal so each AC12 test does not re-inline it (SonarQube 3% gate).
    private func makeMinimalConfig() throws -> ProjectConfig {
        try JSONDecoder().decode(
            ProjectConfig.self,
            from: Data(#"{"account_id":"acc-seg","project":{"id":"proj-seg"}}"#.utf8)
        )
    }

    /// A `ProjectConfig` whose SINGLE 100%-traffic experience (`key == experienceKey`, id `"exp-1"`) is
    /// gated on a `country == countryEquals` audience: the experience references the audience by id
    /// (`"audiences":["aud-1"]`) and the top-level `audiences` array carries the matching country leaf. So
    /// `runExperience(experienceKey)` buckets IFF the audience evaluation sees `country == countryEquals`.
    ///
    /// REPLICATES the proven Core-target wire shape (`ProjectConfigFixtures.audienceJSON` /
    /// `.countryGatedExperienceConfig`), which is invisible across the target boundary — the established
    /// cross-boundary fixture pattern this target already uses (`makeGoalConfig`, `makeFeatureConfig`).
    /// `ConfigAudience.rules` is the `RuleObjectAudience` directly (allOf flattening), wrapping the
    /// `{"rule_type":"country","value":…,"matching":{"match_type":"equals"}}` leaf in the fixed
    /// `OR → AND → OR_WHEN` envelope `RuleAdapterTests` proves decodes end-to-end. Assembled in fragments
    /// (audience → experience → envelope) so each line stays ≤120 chars (SwiftLint `line_length`); the
    /// literal is written ONCE here (SonarQube 3% gate; CPD is token-based, so the shared builder — not
    /// renamed locals — holds the diff under it). `throws` only on malformed JSON.
    /// - Parameter countryEquals: The country code the audience leaf matches with the `equals` operator.
    private func makeCountryGatedConfig(countryEquals: String) throws -> ProjectConfig {
        let leaf = #"{"rule_type":"country","value":"\#(countryEquals)","matching":{"match_type":"equals"}}"#
        let rules = #"{"OR":[{"AND":[{"OR_WHEN":[\#(leaf)]}]}]}"#
        let audience = #"{"id":"aud-1","key":"aud-1-key","type":"transient","rules":\#(rules)}"#
        let variation = #"{"id":"var-1","key":"control","traffic_allocation":100}"#
        let experienceHead = #"{"id":"exp-1","key":"\#(Self.experienceKey)","type":"a/b","#
        let experience = experienceHead + #""audiences":["aud-1"],"locations":[],"variations":[\#(variation)]}"#
        let envelopeHead = #"{"account_id":"acc-seg","project":{"id":"proj-seg"},"#
        let envelope = envelopeHead + #""experiences":[\#(experience)],"audiences":[\#(audience)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(envelope.utf8))
    }

    /// A `ProjectConfig` whose feature-CARRYING experience is gated on a `country == countryEquals`
    /// audience — the FEATURE twin of ``makeCountryGatedConfig``. It SPLICES two PROVEN wire shapes:
    ///   * the `country`-`equals` audience graph from ``makeCountryGatedConfig`` (the `OR → AND →
    ///     OR_WHEN` envelope `RuleAdapterTests` decodes end-to-end), referenced by id `"aud-1"`;
    ///   * the single `fullStackFeature`-bearing experience + top-level `features` entry from
    ///     `Support/TestFixtures.makeFeatureConfig` (id `"feat-exp"`/key `"feat-exp-key"`, the
    ///     `{"id":1,"type":"fullStackFeature",…}` change whose INTEGER id is load-bearing — a quoted
    ///     id degrades the whole experience out of `rawExperiences` — and the matching `features[]`
    ///     entry whose STRING id is `String(featureIdInt)`).
    /// The ONLY change versus `makeFeatureConfig`'s experience is `"audiences":["aud-1"]` in place of
    /// `"audiences":[]`, so the carrier buckets IFF the audience sees `country == countryEquals`. Thus
    /// `runFeature(featureKey)` returns `.enabled` ONLY when a `country` segment satisfying the gate is
    /// in scope — which is exactly what the parity test asserts the FEATURE path must honour.
    ///
    /// `account_id`/`project.id` are `"acc-seg"`/`"proj-seg"` (this suite's owner) so the sticky store
    /// key `"<accountId>-<projectId>-<visitorId>"` the context computes — and the segment overlay reads
    /// under — is well-formed. Assembled in fragments (audience → feature → experience → envelope) so
    /// each line stays ≤120 chars (SwiftLint `line_length`); the spliced shape is written ONCE here, the
    /// sole owner of the feature+audience combination (SonarQube 3% gate; CPD is token-based, so a shared
    /// builder — not renamed locals — holds the diff under it). `throws` only on malformed JSON.
    /// - Parameter countryEquals: The country code the audience leaf matches with the `equals` operator.
    private func makeCountryGatedFeatureConfig(countryEquals: String) throws -> ProjectConfig {
        let leaf = #"{"rule_type":"country","value":"\#(countryEquals)","matching":{"match_type":"equals"}}"#
        let rules = #"{"OR":[{"AND":[{"OR_WHEN":[\#(leaf)]}]}]}"#
        let audience = #"{"id":"aud-1","key":"aud-1","type":"transient","rules":\#(rules)}"#
        let variablesData = #"{"flag":true,"label":"hi"}"#
        let variableTypes = #"[{"key":"flag","type":"boolean"},{"key":"label","type":"string"}]"#
        let changeData = #""data":{"feature_id":10031,"variables_data":\#(variablesData)}"#
        let change = #"{"id":1,"type":"fullStackFeature",\#(changeData)}"#
        let variationHead = #"{"id":"feat-var","key":"feat-var-key","traffic_allocation":100,"#
        let variation = variationHead + #""changes":[\#(change)]}"#
        let experienceHead = #"{"id":"feat-exp","key":"feat-exp-key","type":"a/b","#
        let experience = experienceHead + #""audiences":["aud-1"],"locations":[],"variations":[\#(variation)]}"#
        let featureHead = #"{"id":"10031","name":"\#(Self.featureKey)-name","key":"\#(Self.featureKey)","#
        let feature = featureHead + #""variables":\#(variableTypes)}"#
        let envelopeHead = #"{"account_id":"acc-seg","project":{"id":"proj-seg"},"#
        let envelopeTail = #""experiences":[\#(experience)],"features":[\#(feature)],"audiences":[\#(audience)]}"#
        return try JSONDecoder().decode(ProjectConfig.self, from: Data((envelopeHead + envelopeTail).utf8))
    }

    /// Subscribes a counting observer for `SystemEvent.segments` on `sdk` and returns the live count cell
    /// plus its token. The `LockedBox<Int>` carries the count so the `@Sendable` bus callback mutates it
    /// data-race-free; the caller drains the `MainActor` queue (``EventBus/fire`` delivers on `MainActor`)
    /// before reading. Single owner of the subscribe-and-count wiring so the AC12 fire-count cases do not
    /// each re-inline a `sdk.on(.segments) { box.withLock { $0 += 1 } }` block (SonarQube 3% gate).
    private func countSegments(on sdk: ConvertSDK) async -> (box: LockedBox<Int>, token: EventListenerToken) {
        let box = LockedBox<Int>(0)
        let token = await sdk.on(.segments) { _ in box.withLock { $0 += 1 } }
        return (box, token)
    }

    /// Subscribes a capturing observer for `SystemEvent.segments` on `sdk`, extracting the
    /// `SegmentsPayload.segments` into a `LockedBox<Segments?>` (set on each delivery), and returns the
    /// cell plus its token. The capture pattern-matches the wrapping `EventPayloadValue.segments(_:)`; a
    /// non-`.segments` payload (which this subscription never receives) leaves the cell untouched. Single
    /// owner of the capture wiring (SonarQube 3% gate).
    private func captureSegments(
        on sdk: ConvertSDK
    ) async -> (box: LockedBox<Segments?>, token: EventListenerToken) {
        let box = LockedBox<Segments?>(nil)
        let token = await sdk.on(.segments) { payload in
            if case let .segments(segmentsPayload) = payload {
                box.set(segmentsPayload.segments)
            }
        }
        return (box, token)
    }

    // MARK: - AC12 — setDefaultSegments / setCustomSegments fire .segments exactly once

    /// AC12: `setDefaultSegments` fires `SystemEvent.segments` EXACTLY ONCE. Subscribes a counter, sets the
    /// default segments, drains the `MainActor` callback queue, and asserts a single firing. RED today: the
    /// stub takes `Segments` and is synchronous, so `await context.setDefaultSegments(["country": "US"])`
    /// does not compile; once the GREEN seam lands the assertion holds.
    @Test("setDefaultSegments fires .segments exactly once (AC12)")
    func setDefaultSegmentsFiresOnce() async throws {
        let sut = try await makeReadySDK(config: makeMinimalConfig())
        let context = sut.sdk.createContext(visitorId: "visitor-1")
        let (fireCount, token) = await countSegments(on: sut.sdk)

        await context.setDefaultSegments(["country": Self.gatedCountry])
        await MainActor.run { }

        #expect(fireCount.get == 1, "setDefaultSegments fires .segments exactly once")
        await sut.sdk.off(token)
    }

    /// AC12: `setCustomSegments` fires `SystemEvent.segments` EXACTLY ONCE. The custom-segments twin of
    /// the default-segments fire test — same counter + drain pattern, calling `setCustomSegments`.
    @Test("setCustomSegments fires .segments exactly once (AC12)")
    func setCustomSegmentsFiresOnce() async throws {
        let sut = try await makeReadySDK(config: makeMinimalConfig())
        let context = sut.sdk.createContext(visitorId: "visitor-1")
        let (fireCount, token) = await countSegments(on: sut.sdk)

        await context.setCustomSegments(["seg-1", "seg-2"])
        await MainActor.run { }

        #expect(fireCount.get == 1, "setCustomSegments fires .segments exactly once")
        await sut.sdk.off(token)
    }

    /// AC12: the `.segments` payload CARRIES the updated segments. Captures the delivered
    /// `SegmentsPayload.segments`, sets two default-segment fields, drains, and asserts both fields are
    /// present on the captured `Segments` — proving the bus signal carries the visitor's resolved segments,
    /// not an empty payload.
    @Test("setDefaultSegments payload carries the updated segments (AC12)")
    func setDefaultSegmentsPayloadCarriesSegments() async throws {
        let sut = try await makeReadySDK(config: makeMinimalConfig())
        let context = sut.sdk.createContext(visitorId: "visitor-1")
        let (captured, token) = await captureSegments(on: sut.sdk)

        await context.setDefaultSegments(["country": Self.gatedCountry, "campaign": "launch"])
        await MainActor.run { }

        #expect(captured.get?.country == Self.gatedCountry, "the payload carries the country segment")
        #expect(captured.get?.campaign == "launch", "the payload carries the campaign segment")
        await sut.sdk.off(token)
    }

    // MARK: - AC11 — a segment satisfying the audience rule feeds bucketing

    /// AC11: `runExperience` buckets when a `setDefaultSegments` value SATISFIES the experience's audience
    /// rule, and does NOT bucket when no such segment was set. The single experience is gated on
    /// `country == "US"`:
    ///   * POSITIVE — a context that sets ONLY `country: "US"` via `setDefaultSegments` (NOT via
    ///     `createContext` attributes, so the segment is the genuine source of the country value) buckets
    ///     ⇒ a non-`nil` variation.
    ///   * CONTROL — a context that passes NO attributes and sets NO segment has no `country` at the gate
    ///     ⇒ the audience fails ⇒ `nil`.
    /// RED today: the stub `setDefaultSegments` is a no-op (and the wrong signature), so even the positive
    /// case's `country` never reaches the audience gate — the positive `runExperience` returns `nil`, so the
    /// `#expect(variation != nil)` fails. The control already returns `nil` (audience never satisfied), so
    /// the two assertions together prove segments are what feed the audience evaluation.
    @Test("runExperience buckets when a segment satisfies the audience rule (AC11)")
    func segmentSatisfyingAudienceBuckets() async throws {
        let sut = try await makeReadySDK(config: makeCountryGatedConfig(countryEquals: Self.gatedCountry))

        // POSITIVE: country supplied ONLY via the default segment (no createContext attributes).
        let context = sut.sdk.createContext(visitorId: "v-us")
        await context.setDefaultSegments(["country": Self.gatedCountry])
        let variation = await context.runExperience(Self.experienceKey)
        #expect(variation != nil, "a segment satisfying the country audience buckets the experience")

        // CONTROL: no attributes and no segment ⇒ country absent at the gate ⇒ audience fails ⇒ nil.
        let controlContext = sut.sdk.createContext(visitorId: "v-none")
        let controlVariation = await controlContext.runExperience(Self.experienceKey)
        #expect(controlVariation == nil, "with no country segment the country audience fails — no bucketing")
    }

    // MARK: - AC11/parity: feature audience sees segments

    /// AC11 (JS parity, bd-0ca): `runFeature` must overlay the visitor's segments onto the audience-rule
    /// attribute map exactly as `runExperience` does — JS `context.ts` calls `getVisitorProperties`
    /// identically on the experience AND feature paths, so a feature whose ENABLING experience is gated on
    /// `country == "US"` becomes `.enabled` for a visitor whose `country` segment is `"US"`, and stays
    /// `.disabled` for a visitor that set no such segment. The single feature is carried by an experience
    /// gated on that audience (``makeCountryGatedFeatureConfig``):
    ///   * POSITIVE — a context that sets ONLY `country: "US"` via `setDefaultSegments` (NOT via
    ///     `createContext` attributes, so the SEGMENT is the genuine source of the country value) ⇒ the
    ///     carrier's audience is satisfied ⇒ the feature buckets ⇒ `.enabled`.
    ///   * CONTROL — a context that passes NO attributes and sets NO segment has no `country` at the gate
    ///     ⇒ the audience fails ⇒ the carrier never buckets ⇒ `.disabled`.
    /// RED today: `ConvertContext.runFeature` passes `stringAttributes()` RAW (no `mergedAttributes`
    /// overlay — unlike `runExperience`), so even the positive case's `country` segment never reaches the
    /// audience gate; the carrier's `country == "US"` audience is NOT satisfied and the feature stays
    /// `.disabled`, so the positive `#expect(... == .enabled)` FAILS. The control already resolves to
    /// `.disabled` (audience never satisfied), so the two assertions together prove the SEGMENT is what
    /// must feed the FEATURE audience gate. GREEN overlays the segments on `runFeature`/`runFeatures`.
    ///
    /// `Feature` exposes the enabled-check as `status == .enabled` (there is NO `isEnabled`
    /// property — see `Feature.swift`); this matches the proven `ConvertContextRunFeaturesTests`
    /// assertion convention.
    @Test("runFeature enables a feature when a segment satisfies its audience rule (JS parity)")
    func featureSegmentSatisfyingAudienceEnables() async throws {
        let sut = try await makeReadySDK(config: makeCountryGatedFeatureConfig(countryEquals: Self.gatedCountry))

        // POSITIVE: country supplied ONLY via the default segment (no createContext attributes).
        let context = sut.sdk.createContext(visitorId: "v-feat-us")
        await context.setDefaultSegments(["country": Self.gatedCountry])
        let feature = await context.runFeature(Self.featureKey)
        #expect(feature.status == .enabled, "a segment satisfying the country audience enables the feature")

        // CONTROL: no attributes and no segment ⇒ country absent at the gate ⇒ audience fails ⇒ disabled.
        let control = sut.sdk.createContext(visitorId: "v-feat-none")
        let disabled = await control.runFeature(Self.featureKey)
        #expect(disabled.status == .disabled, "with no country segment the audience fails — feature disabled")
    }
}

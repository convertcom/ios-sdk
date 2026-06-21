// Tests/ConvertSwiftSDKCoreTests/Config/SDKVersionTests.swift
// `@testable` import mirrors the established convention for this target (see ConfigTests);
// a plain import would also reach `SDKVersion.current` since it is `public`, but the
// single `@testable` import keeps this file consistent with its in-folder siblings.
import Testing
@testable import ConvertSwiftSDKCore

/// RED-phase contract for the SDK version single-source-of-truth (Epic 2 / Story 3, CORE-1).
///
/// CONTRACT under test (the GREEN-phase implementer MUST satisfy these):
/// - `SDKVersion.current` is a non-empty `String` that is the single source of truth for the
///   SDK version embedded in the ConvertAgent User-Agent header.
/// - Its initial value is exactly `"1.0.0"`.
/// - It carries a semver-ish shape: three dot-separated components, each a non-negative integer.
///
/// `SDKVersion` does not exist yet, so this suite is EXPECTED to fail to compile (RED).
/// That is the correct outcome of this phase.
@Suite("SDKVersion")
struct SDKVersionTests {
    @Test("current is the non-empty initial version string 1.0.0")
    func currentMatchesInitialVersion() {
        #expect(!SDKVersion.current.isEmpty)
        #expect(SDKVersion.current == "1.0.0")
    }

    /// Independent structural guard on the format — not a re-spelling of the `"1.0.0"` literal
    /// above. A future version bump (e.g. `"1.2.0"`) keeps this test green while a malformed
    /// value (`"1.0"`, `"v1.0.0"`, `"1.0.0-rc"`) fails it.
    @Test("current has a three-component integer semver shape")
    func currentIsSemverShaped() throws {
        let components = SDKVersion.current.split(separator: ".", omittingEmptySubsequences: false)
        #expect(components.count == 3)
        for component in components {
            let parsed = try #require(Int(component), "non-integer semver component: \(component)")
            #expect(parsed >= 0)
        }
    }
}

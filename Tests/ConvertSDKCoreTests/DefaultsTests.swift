// Tests/ConvertSDKCoreTests/DefaultsTests.swift
import Testing
import ConvertSDKCore

@Suite("Defaults")
struct DefaultsTests {
    // One parameterized body covers all six constants (normalized to UInt64) instead
    // of six near-identical assertion lines — keeps the new-duplicated-lines density
    // under the SonarQube gate. The explicit `[(UInt64, UInt64)]` element type keeps
    // the type-checker off the "expression too complex" path that an untyped
    // tuple-literal array of numeric conversions otherwise triggers.
    static let cases: [(actual: UInt64, expected: UInt64)] = [
        (UInt64(Defaults.hashSeed), 9_999),
        (UInt64(Defaults.maxTraffic), 10_000),
        (Defaults.maxHash, 4_294_967_296),
        (UInt64(Defaults.batchSize), 10),
        (UInt64(Defaults.releaseIntervalMs), 1_000),
        (UInt64(Defaults.dataRefreshIntervalMs), 300_000)
    ]

    @Test("Defaults constants hold their specified values", arguments: cases)
    func constant(actual: UInt64, expected: UInt64) {
        #expect(actual == expected, "expected \(expected), got \(actual)")
    }

    /// Locks the declared widths so a future refactor cannot silently widen them.
    /// Assigning into an exact-width local fails to compile if the source type ever
    /// changes — a real structural guard, unlike a tautological `is` check on a
    /// concrete-typed constant (which would also emit an "always true" warning under
    /// the zero-warnings gate, AC7).
    @Test("Defaults numeric widths are exactly as declared")
    func declaredWidths() {
        let seed: UInt32 = Defaults.hashSeed
        let maxHash: UInt64 = Defaults.maxHash
        #expect(seed == 9_999)
        #expect(maxHash == 4_294_967_296)
    }
}

@Suite("LogLevel")
struct LogLevelTests {
    @Test("LogLevel is Comparable in ascending severity order")
    func severityOrdering() {
        #expect(LogLevel.trace < LogLevel.debug)
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.silent)
    }

    @Test("LogLevel spot-checks across the severity range")
    func severitySpotChecks() {
        #expect(LogLevel.trace < LogLevel.warn)
        #expect(LogLevel.error < LogLevel.silent)
    }

    @Test("LogLevel enumerates all six cases")
    func caseCount() {
        #expect(LogLevel.allCases.count == 6)
    }
}

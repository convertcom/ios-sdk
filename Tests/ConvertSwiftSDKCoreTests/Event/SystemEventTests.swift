// Tests/ConvertSwiftSDKCoreTests/Event/SystemEventTests.swift
import Testing
import ConvertSwiftSDKCore

@Suite("SystemEvent")
struct SystemEventTests {
    // (case, exact JS wire rawValue) verified against system-events.ts:12-23.
    // Explicit [(SystemEvent, String)] element type keeps the type-checker off the
    // "expression too complex" path. One parameterized body instead of 10 — SonarQube gate.
    static let wireMappings: [(SystemEvent, String)] = [
        (.ready, "ready"),
        (.configUpdated, "config.updated"),
        (.apiQueueReleased, "api.queue.released"),
        (.bucketing, "bucketing"),
        (.conversion, "conversion"),
        (.segments, "segments"),
        (.locationActivated, "location.activated"),
        (.locationDeactivated, "location.deactivated"),
        (.audiences, "audiences"),
        (.dataStoreQueueReleased, "datastore.queue.released")
    ]

    @Test("SystemEvent is frozen at exactly ten cases")
    func caseCount() {
        #expect(SystemEvent.allCases.count == 10)
    }

    @Test("SystemEvent rawValue matches its JS wire string", arguments: wireMappings)
    func rawValueMatchesWire(event: SystemEvent, wire: String) {
        #expect(event.rawValue == wire, "expected \(wire), got \(event.rawValue)")
    }
}

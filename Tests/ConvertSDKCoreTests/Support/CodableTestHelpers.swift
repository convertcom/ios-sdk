// Tests/ConvertSDKCoreTests/Support/CodableTestHelpers.swift
import Foundation

/// Shared encode-to-String support for the Codable model tests.
///
/// The encoder and the `Encodable` -> `String` conversion live here in ONE place so
/// the three Models test files never copy-paste a ≥10-line encode block (which the
/// SonarQube `new_duplicated_lines_density` gate would flag). Each test calls
/// `encodeJSONString(_:)` and asserts on the returned string.
enum CodableTestHelpers {
    /// A deterministic encoder: `.sortedKeys` makes the emitted key order stable so
    /// substring/field-presence assertions are reproducible across runs and platforms.
    static let sortedKeysEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Encodes `value` with the sorted-keys encoder and returns it as a UTF-8 string.
    ///
    /// Returns `nil` on encode failure or non-UTF-8 output rather than force-unwrapping,
    /// so callers stay free of `try!`/`!` (SwiftLint force-unwrap rule). Tests assert the
    /// result is non-nil before reading it.
    static func encodeJSONString(_ value: some Encodable) -> String? {
        guard let data = try? sortedKeysEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Canonicalises arbitrary JSON `Data` to sorted-key form so two payloads can be
    /// compared independently of source object-member order. Used by the LCD-sentinel
    /// round-trip tests, whose fidelity guarantee is canonical-equivalence (semantic +
    /// sorted-key-stable, zero data loss) — proven by running both the original bytes and
    /// the re-encoded sentinel through this same transform. `.fragmentsAllowed` lets a bare
    /// scalar/array at the top level canonicalise too.
    static func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    /// Canonicalises arbitrary JSON text to sorted-key form (UTF-8 bridge over
    /// `canonical(_ data:)`).
    static func canonical(_ json: String) throws -> Data {
        try canonical(Data(json.utf8))
    }
}

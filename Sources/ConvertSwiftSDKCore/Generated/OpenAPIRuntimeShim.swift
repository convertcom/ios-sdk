// OpenAPIRuntimeShim.swift
//
// VENDORED, BOUNDED, FOUNDATION-ONLY subset of swift-openapi-runtime (tag 1.8.2).
//
// WHY THIS FILE EXISTS
// --------------------
// swift-openapi-generator 1.12.2 emits types-only output that hard-imports
// `@_spi(Generated) OpenAPIRuntime` and references a small set of its symbols. The
// Convert iOS SDK has a ZERO third-party runtime-dependency mandate (NFR16), so we
// cannot link OpenAPIRuntime. Instead — exactly mirroring the project's already
// established vendored-MurmurHash3 pattern — we vendor the EXACT bounded surface the
// generated `ConfigSchemas.swift` uses, as Foundation-only in-repo source with the
// upstream Apache-2.0 attribution preserved.
//
// A later task's `run.sh` strips the `OpenAPIRuntime.` qualifiers from the generated
// file so its references resolve to these MODULE-SCOPE declarations in the SAME
// module (ConvertSwiftSDKCore). For that to work, every symbol below is declared top-level
// (not inside an enum namespace) and `public`.
//
// BOUNDED SURFACE (measured against the FILTERED, config-schemas-only generation):
//   - OpenAPIValueContainer                      (47 uses)
//   - OpenAPIObjectContainer                     (4 uses)
//   - DecodingError.unknownOneOfDiscriminator    (8 uses)
//   - DecodingError.verifyAtLeastOneSchemaIsNotNil (2 uses)
// `verifyAtLeastOneSchemaIsNotNil` transitively needs `failedToDecodeAnySchema`
// → `MultiError` → `PrettyStringConvertible.prettyDescription`, all vendored below.
// `OpenAPIArrayContainer` (0 uses) and `failedToDecodeOneOfSchema` (0 uses after
// filtering) are OMITTED.
//
// MAINTENANCE
// -----------
// This is a HAND-MAINTAINED file (it lives under Generated/ only for locality with
// ConfigSchemas.swift; it is NOT codegen output and is intentionally lint-clean — no
// blanket file-wide lint suppression). The symbol bodies below are copied VERBATIM
// from the upstream sources cited; do not rewrite their logic. Only targeted, justified
// single-line lint suppressions (each annotated inline) are used where verbatim upstream
// code trips an opt-in or default rule (see each site for the justification).
//
// Upstream provenance (do not edit logic; re-sync from these on a runtime bump):
//   - OpenAPIValueContainer, OpenAPIObjectContainer (+ literal extensions):
//       swift-openapi-runtime/Sources/OpenAPIRuntime/Conversion/OpenAPIValue.swift
//   - DecodingError extension methods + MultiError:
//       swift-openapi-runtime/Sources/OpenAPIRuntime/Errors/ErrorExtensions.swift
//   - PrettyStringConvertible:
//       swift-openapi-runtime/Sources/OpenAPIRuntime/Errors/PrettyStringConvertible.swift
//
// `file_length` is disabled file-wide (a single named rule — NOT a blanket `disable all`):
// the task mandates ONE file vendoring the full bounded surface, which unavoidably exceeds
// the 400-line default. All other rules remain enforced.
// swiftlint:disable file_length
//
// The Apache license banner below is preserved VERBATIM from upstream (task requirement).
// Its `//===…===//` rule lines have no space after `//`, which would trip `comment_spacing`;
// the rule is suppressed only across the banner, then immediately re-enabled.
// swiftlint:disable comment_spacing
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftOpenAPIGenerator open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftOpenAPIGenerator project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftOpenAPIGenerator project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
// swiftlint:enable comment_spacing

// `import Foundation` (the Foundation umbrella — NOT third-party) provides every symbol
// this file uses: `NSNull`, `NSNumber`, `CoreFoundation` (`kCFBooleanTrue`, `CFNumberGetType`,
// …), and `LocalizedError` (the `MultiError` conformance). Upstream split these across two
// files — `OpenAPIValue.swift` used narrow `import class Foundation.NSNull/NSNumber` +
// conditional `import CoreFoundation`, while `ErrorExtensions.swift` used a full
// `import Foundation`. Merged here, the full umbrella supersets the narrow imports, so we
// keep only `import Foundation` (the SDK targets Apple platforms only — iOS/macOS/tvOS — so
// the non-Darwin `@preconcurrency` branch and the narrow class imports are redundant).
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - OpenAPIValueContainer
// Verbatim from upstream OpenAPIValue.swift.

/// A container for a value represented by JSON Schema.
///
/// Contains an untyped JSON value. In some cases, the structure of the data
/// may not be known in advance and must be dynamically iterated at decoding
/// time. This is an advanced feature that requires extra validation of
/// the input before use, and is at a higher risk of a security vulnerability.
///
/// Supported nested Swift types:
/// - `nil`
/// - `String`
/// - `Int`
/// - `Double`
/// - `Bool`
/// - `[Any?]`
/// - `[String: Any?]`
///
/// Where the element type of the array, and the value type of the dictionary
/// must also be supported types.
///
/// - Important: This type is expensive at runtime; try to avoid it.
/// Define the structure of your types in the OpenAPI document instead.
public struct OpenAPIValueContainer: Codable, Hashable, Sendable {

    /// The underlying dynamic value.
    public var value: (any Sendable)?

    /// Creates a new container with the given validated value.
    /// - Parameter value: A value of a JSON-compatible type, such as `String`,
    /// `[Any]`, and `[String: Any]`.
    init(validatedValue value: (any Sendable)?) { self.value = value }

    /// Creates a new container with the given unvalidated value.
    ///
    /// First it validates that the provided value is supported, and throws
    /// otherwise.
    /// - Parameter unvalidatedValue: A value of a JSON-compatible type,
    /// such as `String`, `[Any]`, and `[String: Any]`.
    /// - Throws: When the value is not supported.
    public init(unvalidatedValue: (any Sendable)? = nil) throws {
        try self.init(validatedValue: Self.tryCast(unvalidatedValue))
    }

    // MARK: Private

    /// Returns the specified value cast to a supported type.
    /// - Parameter value: An untyped value.
    /// - Returns: A cast value if supported.
    /// - Throws: When the value is not supported.
    static func tryCast(_ value: (any Sendable)?) throws -> (any Sendable)? {
        guard let value = value else { return nil }
        #if canImport(Foundation)
        if value is NSNull { return value }
        #endif
        if let array = value as? [(any Sendable)?] { return try array.map(tryCast(_:)) }
        if let dictionary = value as? [String: (any Sendable)?] { return try dictionary.mapValues(tryCast(_:)) }
        if let value = tryCastPrimitiveType(value) { return value }
        throw EncodingError.invalidValue(
            value,
            .init(codingPath: [], debugDescription: "Type '\(type(of: value))' is not a supported OpenAPI value.")
        )
    }

    /// Returns the specified value cast to a supported primitive type.
    /// - Parameter value: An untyped value.
    /// - Returns: A cast value if supported, nil otherwise.
    static func tryCastPrimitiveType(_ value: any Sendable) -> (any Sendable)? {
        switch value {
        case is String, is Int, is Bool, is Double: return value
        default: return nil
        }
    }

    // MARK: Decodable

    /// Initializes an `OpenAPIValueContainer` by decoding it from a decoder.
    ///
    /// - Parameter decoder: The decoder to read data from.
    /// - Throws: An error if the decoding process encounters issues or if the data is corrupted.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.init(validatedValue: nil)
        } else if let item = try? container.decode(Bool.self) {
            self.init(validatedValue: item)
        } else if let item = try? container.decode(Int.self) {
            self.init(validatedValue: item)
        } else if let item = try? container.decode(Double.self) {
            self.init(validatedValue: item)
        } else if let item = try? container.decode(String.self) {
            self.init(validatedValue: item)
        } else if let item = try? container.decode([OpenAPIValueContainer].self) {
            self.init(validatedValue: item.map(\.value))
        } else if let item = try? container.decode([String: OpenAPIValueContainer].self) {
            self.init(validatedValue: item.mapValues(\.value))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "OpenAPIValueContainer cannot be decoded"
            )
        }
    }

    // MARK: Encodable

    /// Encodes the `OpenAPIValueContainer` and writes it to an encoder.
    ///
    /// - Parameter encoder: The encoder to which the value should be encoded.
    /// - Throws: An error if the encoding process encounters issues or if the value is invalid.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let value = value else {
            try container.encodeNil()
            return
        }
        #if canImport(Foundation)
        if value is NSNull {
            try container.encodeNil()
            return
        }
        #if canImport(CoreFoundation)
        if let nsNumber = value as? NSNumber {
            try encode(nsNumber, to: &container)
            return
        }
        #endif
        #endif
        switch value {
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [(any Sendable)?]:
            try container.encode(value.map(OpenAPIValueContainer.init(validatedValue:)))
        case let value as [String: (any Sendable)?]:
            try container.encode(value.mapValues(OpenAPIValueContainer.init(validatedValue:)))
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: container.codingPath, debugDescription: "OpenAPIValueContainer cannot be encoded")
            )
        }
    }
    #if canImport(CoreFoundation)
    /// Encodes the provided NSNumber based on its internal representation.
    /// - Parameters:
    ///   - value: The NSNumber that boxes one of possibly many different types of values.
    ///   - container: The container to encode the value in.
    /// - Throws: An error if the encoding process encounters issues or if the value is invalid.
    private func encode(_ value: NSNumber, to container: inout any SingleValueEncodingContainer) throws {
        if value === kCFBooleanTrue {
            try container.encode(true)
        } else if value === kCFBooleanFalse {
            try container.encode(false)
        } else {
            #if canImport(ObjectiveC)
            let nsNumber = value as CFNumber
            #else
            let nsNumber = unsafeBitCast(value, to: CFNumber.self)
            #endif
            let type = CFNumberGetType(nsNumber)
            switch type {
            case .sInt8Type, .charType: try container.encode(value.int8Value)
            case .sInt16Type, .shortType: try container.encode(value.int16Value)
            case .sInt32Type, .intType: try container.encode(value.int32Value)
            case .sInt64Type, .longLongType: try container.encode(value.int64Value)
            case .float32Type, .floatType: try container.encode(value.floatValue)
            case .float64Type, .doubleType, .cgFloatType: try container.encode(value.doubleValue)
            case .nsIntegerType, .longType, .cfIndexType: try container.encode(value.intValue)
            default:
                throw EncodingError.invalidValue(
                    value,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "OpenAPIValueContainer cannot encode NSNumber of the underlying type: \(type)"
                    )
                )
            }
        }
    }
    #endif

    // MARK: Equatable

    // The verbatim upstream `==` switches over every supported JSON value type; its branch
    // count exceeds the default `cyclomatic_complexity` limit. Suppressed (rule-specific) via
    // a region wrapping the whole function — `disable:next` cannot be placed between the doc
    // comment and the declaration without orphaning the doc comment — and kept byte-identical
    // to upstream for re-sync rather than restructured.
    // swiftlint:disable cyclomatic_complexity
    /// Compares two `OpenAPIValueContainer` instances for equality.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side `OpenAPIValueContainer` to compare.
    ///   - rhs: The right-hand side `OpenAPIValueContainer` to compare.
    /// - Returns: `true` if the two instances are equal, `false` otherwise.
    public static func == (lhs: OpenAPIValueContainer, rhs: OpenAPIValueContainer) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil), is (Void, Void): return true
        case let (lhs as Bool, rhs as Bool): return lhs == rhs
        case let (lhs as Int, rhs as Int): return lhs == rhs
        case let (lhs as Int64, rhs as Int64): return lhs == rhs
        case let (lhs as Int32, rhs as Int32): return lhs == rhs
        case let (lhs as Float, rhs as Float): return lhs == rhs
        case let (lhs as Double, rhs as Double): return lhs == rhs
        case let (lhs as String, rhs as String): return lhs == rhs
        case let (lhs as [(any Sendable)?], rhs as [(any Sendable)?]):
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs)
                .allSatisfy { lhs, rhs in
                    OpenAPIValueContainer(validatedValue: lhs) == OpenAPIValueContainer(validatedValue: rhs)
                }
        case let (lhs as [String: (any Sendable)?], rhs as [String: (any Sendable)?]):
            guard lhs.count == rhs.count else { return false }
            guard Set(lhs.keys) == Set(rhs.keys) else { return false }
            for key in lhs.keys {
                // Force-unwrap is safe: the `Set(keys)` equality guard above proves every
                // `lhs` key is also present in `rhs` (verbatim upstream logic). The `!` sits
                // on the second line of a multi-line `guard`, so a disable/enable region —
                // not `disable:next` — is needed to cover it.
                // swiftlint:disable force_unwrapping
                guard
                    OpenAPIValueContainer(validatedValue: lhs[key]!) == OpenAPIValueContainer(validatedValue: rhs[key]!)
                else { return false }
                // swiftlint:enable force_unwrapping
            }
            return true
        default: return false
        }
    }
    // swiftlint:enable cyclomatic_complexity

    // MARK: Hashable

    /// Hashes the `OpenAPIValueContainer` instance into a hasher.
    ///
    /// - Parameter hasher: The hasher used to compute the hash value.
    public func hash(into hasher: inout Hasher) {
        switch value {
        case let value as Bool: hasher.combine(value)
        case let value as Int: hasher.combine(value)
        case let value as Double: hasher.combine(value)
        case let value as String: hasher.combine(value)
        case let value as [(any Sendable)?]:
            for item in value { hasher.combine(OpenAPIValueContainer(validatedValue: item)) }
        case let value as [String: (any Sendable)?]:
            for (key, itemValue) in value {
                hasher.combine(key)
                hasher.combine(OpenAPIValueContainer(validatedValue: itemValue))
            }
        default: break
        }
    }
}

extension OpenAPIValueContainer: ExpressibleByBooleanLiteral {
    /// Creates an `OpenAPIValueContainer` with the provided boolean value.
    ///
    /// - Parameter value: The boolean value to store in the container.
    public init(booleanLiteral value: BooleanLiteralType) { self.init(validatedValue: value) }
}

extension OpenAPIValueContainer: ExpressibleByStringLiteral {
    /// Creates an `OpenAPIValueContainer` with the provided string value.
    ///
    /// - Parameter value: The string value to store in the container.
    public init(stringLiteral value: String) { self.init(validatedValue: value) }
}

extension OpenAPIValueContainer: ExpressibleByNilLiteral {
    /// Creates an `OpenAPIValueContainer` with a `nil` value.
    ///
    /// - Parameter nilLiteral: The `nil` literal.
    public init(nilLiteral: ()) { self.init(validatedValue: nil) }
}

extension OpenAPIValueContainer: ExpressibleByIntegerLiteral {
    /// Creates an `OpenAPIValueContainer` with the provided integer value.
    ///
    /// - Parameter value: The integer value to store in the container.
    public init(integerLiteral value: Int) { self.init(validatedValue: value) }
}

extension OpenAPIValueContainer: ExpressibleByFloatLiteral {
    /// Creates an `OpenAPIValueContainer` with the provided floating-point value.
    ///
    /// - Parameter value: The floating-point value to store in the container.
    public init(floatLiteral value: Double) { self.init(validatedValue: value) }
}

// MARK: - OpenAPIObjectContainer
// Verbatim from upstream OpenAPIValue.swift.

/// A container for a dictionary with values represented by JSON Schema.
///
/// Contains a dictionary of untyped JSON values. In some cases, the structure
/// of the data may not be known in advance and must be dynamically iterated
/// at decoding time. This is an advanced feature that requires extra
/// validation of the input before use, and is at a higher risk of a security
/// vulnerability.
///
/// Supported nested Swift types:
/// - `nil`
/// - `String`
/// - `Int`
/// - `Double`
/// - `Bool`
/// - `[Any?]`
/// - `[String: Any?]`
///
/// Where the element type of the array, and the value type of the dictionary
/// must also be supported types.
///
/// - Important: This type is expensive at runtime; try to avoid it.
/// Define the structure of your types in the OpenAPI document instead.
public struct OpenAPIObjectContainer: Codable, Hashable, Sendable {

    /// The underlying dynamic dictionary value.
    public var value: [String: (any Sendable)?]

    /// Creates a new container with the given validated dictionary.
    /// - Parameter value: A dictionary value.
    init(validatedValue value: [String: (any Sendable)?]) { self.value = value }

    /// Creates a new empty container.
    public init() { self.init(validatedValue: [:]) }

    /// Creates a new container with the given unvalidated value.
    ///
    /// First it validates that the values of the provided dictionary
    /// are supported, and throws otherwise.
    /// - Parameter unvalidatedValue: A dictionary with values of
    /// JSON-compatible types.
    /// - Throws: When the value is not supported.
    public init(unvalidatedValue: [String: (any Sendable)?]) throws {
        try self.init(validatedValue: Self.tryCast(unvalidatedValue))
    }

    // MARK: Private

    /// Returns the specified value cast to a supported dictionary.
    /// - Parameter value: A dictionary with untyped values.
    /// - Returns: A cast dictionary if values are supported.
    /// - Throws: If an unsupported value is found.
    static func tryCast(_ value: [String: (any Sendable)?]) throws -> [String: (any Sendable)?] {
        try value.mapValues(OpenAPIValueContainer.tryCast(_:))
    }

    // MARK: Decodable

    /// Creates an `OpenAPIValueContainer` by decoding it from a single-value container in a given decoder.
    ///
    /// - Parameter decoder: The decoder used to decode the container.
    /// - Throws: An error if the decoding process encounters an issue or if the data
    ///   does not match the expected format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let item = try container.decode([String: OpenAPIValueContainer].self)
        self.init(validatedValue: item.mapValues(\.value))
    }

    // MARK: Encodable

    /// Encodes the `OpenAPIValueContainer` into a format that can be stored or transmitted via the given encoder.
    ///
    /// - Parameter encoder: The encoder used to perform the encoding.
    /// - Throws: An error if the encoding process encounters an issue or if the data
    ///   does not match the expected format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.mapValues(OpenAPIValueContainer.init(validatedValue:)))
    }

    // MARK: Equatable

    /// Compares two `OpenAPIObjectContainer` instances for equality by comparing their inner key-value dictionaries.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side `OpenAPIObjectContainer` to compare.
    ///   - rhs: The right-hand side `OpenAPIObjectContainer` to compare.
    ///
    /// - Returns: `true` if the `OpenAPIObjectContainer` instances are equal, `false` otherwise.
    public static func == (lhs: OpenAPIObjectContainer, rhs: OpenAPIObjectContainer) -> Bool {
        // `lv`/`rv` are upstream's 2-char names; kept verbatim. `identifier_name` (min 3)
        // is suppressed only for these two bindings, then re-enabled.
        // swiftlint:disable identifier_name
        let lv = lhs.value
        let rv = rhs.value
        // swiftlint:enable identifier_name
        guard lv.count == rv.count else { return false }
        guard Set(lv.keys) == Set(rv.keys) else { return false }
        for key in lv.keys {
            // Force-unwrap is safe: the `Set(keys)` equality guard above proves every
            // `lv` key is also present in `rv` (verbatim upstream logic).
            // swiftlint:disable:next force_unwrapping
            guard OpenAPIValueContainer(validatedValue: lv[key]!) == OpenAPIValueContainer(validatedValue: rv[key]!)
            else { return false }
        }
        return true
    }

    // MARK: Hashable

    /// Hashes the `OpenAPIObjectContainer` instance into the provided `Hasher`.
    ///
    /// - Parameter hasher: The `Hasher` into which the hash value is combined.
    public func hash(into hasher: inout Hasher) {
        for (key, itemValue) in value {
            hasher.combine(key)
            hasher.combine(OpenAPIValueContainer(validatedValue: itemValue))
        }
    }
}

// MARK: - DecodingError extensions
// Verbatim from upstream ErrorExtensions.swift. The generated config code calls
// `unknownOneOfDiscriminator` and `verifyAtLeastOneSchemaIsNotNil`; the latter
// transitively needs `failedToDecodeAnySchema` → `MultiError`. `failedToDecodeOneOfSchema`
// (unused after filtering) is omitted. The `@_spi(Generated)` attribute is dropped from
// these declarations because the SPI module (OpenAPIRuntime) is not imported here; the
// generated code's call sites resolve to these same-module `public` methods directly.

extension DecodingError {

    /// Returns a decoding error used by the anyOf decoder when not a single
    /// child schema decodes the received payload.
    /// - Parameters:
    ///   - type: The type representing the anyOf schema in which the decoding
    ///   occurred.
    ///   - codingPath: The coding path to the decoder that attempted to decode
    ///   the type.
    ///   - errors: The errors encountered when decoding individual cases.
    /// - Returns: A decoding error.
    static func failedToDecodeAnySchema(type: Any.Type, codingPath: [any CodingKey], errors: [any Error]) -> Self {
        DecodingError.valueNotFound(
            type,
            DecodingError.Context.init(
                codingPath: codingPath,
                debugDescription: "The anyOf structure did not decode into any child schema.",
                underlyingError: MultiError(errors: errors)
            )
        )
    }

    /// Returns a decoding error used by the oneOf decoder when
    /// the discriminator property contains an unknown schema name.
    /// - Parameters:
    ///   - discriminatorKey: The discriminator coding key.
    ///   - discriminatorValue: The unknown value of the discriminator.
    ///   - codingPath: The coding path to the decoder that attempted to decode
    ///   the type, with the discriminator value as the last component.
    /// - Returns: A decoding error.
    public static func unknownOneOfDiscriminator(
        discriminatorKey: any CodingKey,
        discriminatorValue: String,
        codingPath: [any CodingKey]
    ) -> Self {
        DecodingError.keyNotFound(
            discriminatorKey,
            DecodingError.Context.init(
                codingPath: codingPath,
                debugDescription:
                    "The oneOf structure does not contain the provided discriminator value '\(discriminatorValue)'."
            )
        )
    }

    /// Verifies that the anyOf decoder successfully decoded at least one
    /// child schema, and throws an error otherwise.
    /// - Parameters:
    ///   - values: An array of optional values to check.
    ///   - type: The type representing the anyOf schema in which the decoding
    ///   occurred.
    ///   - codingPath: The coding path to the decoder that attempted to decode
    ///   the type.
    ///   - errors: The errors encountered when decoding individual cases.
    /// - Throws: An error of type `DecodingError.failedToDecodeAnySchema` if none of the
    ///   child schemas were successfully decoded.
    public static func verifyAtLeastOneSchemaIsNotNil(
        _ values: [Any?],
        type: Any.Type,
        codingPath: [any CodingKey],
        errors: [any Error]
    ) throws {
        guard values.contains(where: { $0 != nil }) else {
            throw DecodingError.failedToDecodeAnySchema(type: type, codingPath: codingPath, errors: errors)
        }
    }
}

// MARK: - MultiError
// Verbatim from upstream ErrorExtensions.swift.

/// A wrapper of multiple errors, for example collected during a parallelized
/// operation from the individual subtasks.
struct MultiError: Swift.Error, LocalizedError, CustomStringConvertible {

    /// The multiple underlying errors.
    var errors: [any Error]

    var description: String {
        let combinedDescription =
            errors.map { error in
                guard let error = error as? (any PrettyStringConvertible) else { return "\(error)" }
                return error.prettyDescription
            }
            .enumerated().map { ($0.offset + 1, $0.element) }.map { "Error \($0.0): [\($0.1)]" }.joined(separator: ", ")
        return "MultiError (contains \(errors.count) error\(errors.count == 1 ? "" : "s")): \(combinedDescription)"
    }

    var errorDescription: String? {
        if let first = errors.first {
            return "Mutliple errors encountered, first one: \(first.localizedDescription)."
        } else {
            return "No errors"
        }
    }
}

// MARK: - PrettyStringConvertible
// Verbatim from upstream PrettyStringConvertible.swift.

/// A helper protocol for customizing descriptions.
internal protocol PrettyStringConvertible {

    /// A pretty string description.
    var prettyDescription: String { get }
}

// MARK: - Decoder / Encoder coding SPI
// Verbatim from upstream swift-openapi-runtime/Sources/OpenAPIRuntime/Conversion/CodableExtensions.swift
// (tag 1.8.2, Apache-2.0; same SPDX banner reproduced at the top of this file). The generated config
// code calls these as bare methods on `decoder`/`encoder`: `ensureNoAdditionalProperties(knownKeys:)`,
// `decodeFromSingleValueContainer(_:)`, `decodeAdditionalProperties(knownKeys:)`,
// `encodeToSingleValueContainer(_:)`, `encodeAdditionalProperties(_:)`, and
// `encodeFirstNonNilValueToSingleValueContainer(_:)`. The `@_spi(Generated)` attribute is dropped from
// the `extension Decoder` / `extension Encoder` declarations because the SPI module (OpenAPIRuntime) is
// not imported here; these are the SDK's own same-module `public` methods, which the generated code's
// call sites resolve to directly. The bodies use `OpenAPIValueContainer` / `OpenAPIObjectContainer`
// (vendored above) and need no imports beyond the Foundation umbrella already imported at the top.
// The private `StringKey` is an implementation detail of these methods; there is no collision with the
// existing sources. Bodies are byte-identical to upstream; do not rewrite their logic on re-sync.

extension Decoder {

    // MARK: - Coding SPI

    /// Validates that no undocumented keys are present.
    ///
    /// - Throws: When at least one undocumented key is found.
    /// - Parameter knownKeys: A set of known and already decoded keys.
    public func ensureNoAdditionalProperties(knownKeys: Set<String>) throws {
        let (unknownKeys, container) = try unknownKeysAndContainer(knownKeys: knownKeys)
        guard unknownKeys.isEmpty else {
            // Force-unwrap is safe: this branch only runs when the `unknownKeys.isEmpty`
            // guard fails, so `unknownKeys` is non-empty and `.first` is always present
            // (verbatim upstream logic). Suppressed only for this single statement.
            // swiftlint:disable:next force_unwrapping
            let key = unknownKeys.sorted().first!
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription:
                    "Additional properties are disabled, but found \(unknownKeys.count) unknown keys during decoding"
            )
        }
    }

    /// Returns decoded additional properties.
    ///
    /// The included properties are those still present in the decoder but
    /// not already decoded and passed in as known keys.
    /// - Parameter knownKeys: Known and already decoded keys.
    /// - Returns: A container with the decoded undocumented properties.
    /// - Throws: An error if decoding additional properties fails.
    public func decodeAdditionalProperties(knownKeys: Set<String>) throws -> OpenAPIObjectContainer {
        let (unknownKeys, container) = try unknownKeysAndContainer(knownKeys: knownKeys)
        guard !unknownKeys.isEmpty else { return .init() }
        let keyValuePairs: [(String, (any Sendable)?)] = try unknownKeys.map { key in
            (key.stringValue, try container.decode(OpenAPIValueContainer.self, forKey: key).value)
        }
        return .init(validatedValue: Dictionary(uniqueKeysWithValues: keyValuePairs))
    }

    /// Returns decoded additional properties.
    ///
    /// The included properties are those still present in the decoder but
    /// not already decoded and passed in as known keys.
    /// - Parameter knownKeys: Known and already decoded keys.
    /// - Returns: A container with the decoded undocumented properties.
    /// - Throws: An error if there are issues with decoding the additional properties.
    public func decodeAdditionalProperties<T: Decodable>(knownKeys: Set<String>) throws -> [String: T] {
        let (unknownKeys, container) = try unknownKeysAndContainer(knownKeys: knownKeys)
        guard !unknownKeys.isEmpty else { return .init() }
        let keyValuePairs: [(String, T)] = try unknownKeys.compactMap { key in
            (key.stringValue, try container.decode(T.self, forKey: key))
        }
        return .init(uniqueKeysWithValues: keyValuePairs)
    }

    /// Returns the decoded value by using a single value container.
    /// - Parameter type: The type to decode.
    /// - Returns: The decoded value.
    /// - Throws: An error if there are issues with decoding the value from the single value container.
    public func decodeFromSingleValueContainer<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let container = try singleValueContainer()
        return try container.decode(T.self)
    }

    // MARK: - Private

    /// Returns the keys in the given decoder that are not present
    /// in the `knownKeys` set.
    ///
    /// This is used to implement the `additionalProperties` feature.
    /// - Parameter knownKeys: A set of known keys that have already been decoded.
    /// - Returns: A tuple containing two values: a set of unknown keys and a keyed decoding container
    ///            for further decoding of the unknown properties.
    /// - Throws: An error if there are issues with creating the decoding container or identifying
    ///           the unknown keys.
    private func unknownKeysAndContainer(knownKeys: Set<String>) throws -> (
        Set<StringKey>, KeyedDecodingContainer<StringKey>
    ) {
        let container = try container(keyedBy: StringKey.self)
        let unknownKeys = Set(container.allKeys).subtracting(knownKeys.map(StringKey.init(_:)))
        return (unknownKeys, container)
    }
}

extension Encoder {
    /// Encodes additional properties into the encoder.
    ///
    /// The properties are encoded directly into the encoder, rather that
    /// into a nested container.
    /// - Parameter additionalProperties: A container of additional properties.
    /// - Throws: An error if there are issues with encoding the additional properties.
    public func encodeAdditionalProperties(_ additionalProperties: OpenAPIObjectContainer) throws {
        var container = container(keyedBy: StringKey.self)
        for (key, value) in additionalProperties.value {
            try container.encode(OpenAPIValueContainer(unvalidatedValue: value), forKey: .init(key))
        }
    }

    /// Encodes additional properties into the encoder.
    ///
    /// The properties are encoded directly into the encoder, rather that
    /// into a nested container.
    /// - Parameter additionalProperties: A container of additional properties.
    /// - Throws: An error if there are issues with encoding the additional properties.
    public func encodeAdditionalProperties<T: Encodable>(_ additionalProperties: [String: T]) throws {
        var container = container(keyedBy: StringKey.self)
        for (key, value) in additionalProperties { try container.encode(value, forKey: .init(key)) }
    }

    /// Encodes the value into the encoder using a single value container.
    /// - Parameter value: The value to encode.
    /// - Throws: An error if there are issues with encoding the value.
    public func encodeToSingleValueContainer<T: Encodable>(_ value: T) throws {
        var container = singleValueContainer()
        try container.encode(value)
    }

    /// Encodes the first non-nil value from the provided array into
    /// the encoder using a single value container.
    /// - Parameter values: An array of optional values.
    /// - Throws: An error if there are issues with encoding the value.
    public func encodeFirstNonNilValueToSingleValueContainer(_ values: [(any Encodable)?]) throws {
        for value in values {
            if let value {
                try encodeToSingleValueContainer(value)
                return
            }
        }
    }
}

/// A freeform String coding key for decoding undocumented values.
private struct StringKey: CodingKey, Hashable, Comparable {

    var stringValue: String
    var intValue: Int? { Int(stringValue) }

    init(_ string: String) { self.stringValue = string }

    init?(stringValue: String) { self.stringValue = stringValue }

    init?(intValue: Int) { self.stringValue = String(intValue) }

    static func < (lhs: StringKey, rhs: StringKey) -> Bool { lhs.stringValue < rhs.stringValue }
}

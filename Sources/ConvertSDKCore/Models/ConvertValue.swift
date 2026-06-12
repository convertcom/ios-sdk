// ConvertValue.swift
// A closed sum type over the four scalar values the SDK accepts as visitor/segment attribute
// payloads (string, int, double, bool). Foundation-only — part of the pure-logic
// ConvertSDKCore target.

import Foundation

/// The four scalar value kinds an attribute payload may carry on the wire and through the
/// rule/segment engine. A value enum, so it is trivially `Sendable` and `Equatable` with no
/// suppressions — the public boundary stays type-safe instead of leaking raw `Any`.
public enum ConvertValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// Coerces a loosely-typed `Any` (e.g. a value pulled out of a `[String: Any]` attribute
    /// map) into the matching case, or `nil` when the value is not one of the four supported
    /// scalars (a nested dictionary, array, `NSNull`, custom object, etc.).
    ///
    /// ── Why the Bool check is special-cased FIRST via CoreFoundation ──────────────────────
    /// In Swift a `Bool` and an `Int` boxed into `Any` BOTH bridge through `NSNumber`, so the
    /// naive `value as? Int ?? value as? Bool` ladder misclassifies: `true` casts cleanly to
    /// `Int 1` and `30` casts cleanly to `Bool true`, collapsing the two types. The reliable
    /// discriminator is the underlying CoreFoundation type tag: a bridged Swift `Bool` is a
    /// `CFBoolean` (`CFBooleanGetTypeID()`), whereas a bridged `Int` is a `CFNumber`. We
    /// therefore inspect `CFGetTypeID` on the boxed object FIRST — only a genuine boolean takes
    /// the `.bool` branch; everything else falls through to the numeric/string casts. This keeps
    /// `ConvertValue(any: true) == .bool(true)` and `ConvertValue(any: 30) == .int(30)` exact.
    /// `CoreFoundation` ships inside `Foundation`, so this stays within the Foundation-only
    /// constraint (no `import Security`/`UIKit`/`AppKit`).
    public init?(any value: Any) {
        let object = value as AnyObject
        if CFGetTypeID(object) == CFBooleanGetTypeID() {
            // Only a true `CFBoolean` reaches here; `booleanValue` reads the wrapped flag.
            self = .bool((object as? NSNumber)?.boolValue ?? false)
            return
        }
        // Bool is now excluded, so the remaining casts cannot be hijacked by a boolean. Int is
        // checked before Double so an integral value keeps its `.int` case rather than widening
        // to `.double`.
        if let intValue = value as? Int {
            self = .int(intValue)
        } else if let doubleValue = value as? Double {
            self = .double(doubleValue)
        } else if let stringValue = value as? String {
            self = .string(stringValue)
        } else {
            // Unsupported payload (nested dictionary/array/object/NSNull/…): reject so callers
            // can drop or surface it rather than silently coercing.
            return nil
        }
    }

    /// Reconstructs the wrapped scalar as a loosely-typed `Any`, so a value that came in through
    /// ``init(any:)`` can be handed back to APIs that speak `Any` (e.g. analytics payloads).
    /// `.int(30).anyValue as? Int == 30`, `.bool(true).anyValue as? Bool == true`, and so on.
    public var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        }
    }
}

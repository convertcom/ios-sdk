// StorageKeys.swift
// The reverse-DNS storage keys under which the visitor ID is persisted, kept in one place so
// the Keychain entry and its key/value-store mirror can never drift apart. Foundation-only —
// part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Namespaced persistence keys for the visitor identity. `internal` (matching the resolver that
/// consumes them) because nothing outside the module addresses these stores directly. Declaring
/// both keys once is load-bearing: ``VisitorContextManager`` writes the canonical value under
/// ``visitorId`` (Keychain) and mirrors it under ``visitorIdMirror`` (key/value store); a typo in
/// either copy would silently split the identity across two keys and break ID persistence.
internal enum StorageKeys {
    /// Canonical visitor-ID key — the Keychain entry that survives app reinstalls.
    static let visitorId = "com.convert.sdk.visitorId"

    /// Mirror key in the key/value store — the fallback read when the Keychain misses, and the
    /// backfill target so a freshly generated (or Keychain-recovered) ID is observable in both.
    static let visitorIdMirror = "com.convert.sdk.visitorIdMirror"
}

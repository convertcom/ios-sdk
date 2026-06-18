// CacheLevel.swift
// CDN cache level applied to config fetches (Epic 2 / Story 2).
// Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// CDN cache level applied when fetching project configuration.
///
/// - ``normal``: standard CDN caching.
/// - ``low``: appends `_conv_low_cache=1` on the config fetch to request a lower cache TTL
///   (FR3, wired in Story 2.3).
public enum CacheLevel: String, Sendable, CaseIterable {
    /// Standard CDN caching.
    case normal
    /// Requests a lower CDN cache TTL via `_conv_low_cache=1` on the config fetch.
    case low
}

import Foundation

/// Coarse lifecycle of the SDK's configuration load, surfaced to the UI.
///
/// STUB for Story 7.1. This minimal three-case enum lets the demo publish a
/// readiness signal today. Story 7.6 owns the *full* Loading -> Loaded -> Failed
/// state machine (config-fetch timeout, WARN-before-READY detection, retry/log
/// watching); this type is the seam it grows into. Keep it minimal until then.
enum ConfigState: Equatable {
    /// Readiness has been kicked off and the first config load is in flight.
    case loading
    /// The first config load resolved (live or degraded from cache).
    case loaded
    /// The configuration was unrecoverable; `reason` carries a short description.
    case failed(reason: String)
}

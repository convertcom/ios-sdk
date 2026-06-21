import Foundation

/// Coarse lifecycle of the SDK's configuration load, surfaced to the UI.
///
/// The three-branch readiness machine the Config screen observes. ``DemoViewModel``'s
/// `start()` driver (in `DemoViewModel+Config.swift`) races `ConvertSwiftSDK.ready()` against
/// a fixed readiness timeout and lands exactly one terminal case:
/// - ``loaded(fetchedAt:)`` when `ready()` resolves first (live or degraded-from-cache),
///   stamped with the wall-clock instant the load resolved;
/// - ``failed(reason:)`` when `ready()` throws a `ConvertError` (the `reason` carries its
///   `localizedDescription`) OR when the readiness timeout wins the race first (the
///   `reason` is the timed-out message).
enum ConfigState: Equatable {
    /// Readiness has been kicked off and the first config load is in flight.
    case loading
    /// The first config load resolved (live or degraded from cache); `fetchedAt` stamps
    /// the instant it resolved, for the Config screen's "fetched at" line.
    case loaded(fetchedAt: Date)
    /// The configuration was unrecoverable (a thrown `ConvertError`) or the readiness
    /// timeout elapsed first; `reason` carries a short, human-readable description.
    case failed(reason: String)
}

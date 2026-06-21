// EventUploader.swift
// Port: tracking-event upload abstraction.
// Foundation-only — part of the pure-logic ConvertSwiftSDKCore target.

import Foundation

/// Uploads batches of tracking events to the Convert serving API.
///
/// This port abstracts over both foreground and background delivery paths: the concrete
/// adapter (Epic 2) decides whether a given batch ships immediately on a foreground
/// session or is handed to a background task. Pure logic depends only on this contract,
/// never on the transport mechanism. The payload is the existing ``TrackingEvent`` type.
public protocol EventUploader: Sendable {
    /// Uploads the given tracking events, throwing if delivery fails.
    func upload(_ events: [TrackingEvent]) async throws
}

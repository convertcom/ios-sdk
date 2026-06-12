// DecisionStore.swift
// Visitor-keyed decision store — the eventual home for sticky variations, goal de-duplication,
// and resolved segments. This story creates the actor and wires its injection only; the
// behaviour lands later. Foundation-only — part of the pure-logic ConvertSDKCore target.

import Foundation

/// Visitor-keyed decision store (sticky variations, goal-dedup, segments). The sticky/dedup/LRU
/// logic arrives in Stories 3.4 / 4.2; this story creates the `actor` and wires injection only,
/// so callers can hold a reference now without the storage semantics existing yet. An `actor`
/// (not a `final class`) because all future mutable state — the per-visitor decision maps — must
/// be isolated to keep concurrent reads/writes race-free with no locks (AR12).
public actor DecisionStore {
    /// Creates an empty decision store. No-arg for now; the dependencies the real implementation
    /// needs (clock, capacity limits) get injected when the logic lands in Stories 3.4 / 4.2.
    public init() {}
}

// ConvertContext+Completion.swift
// Completion-handler bridge for ConvertContext's async run methods (Epic 3 / Story 5).
// For UIKit/Objective-C-style call sites that prefer a callback over `await`.

import Foundation

public extension ConvertContext {
    /// Completion-handler overload of ``runExperiences(enableTracking:)``. The `[Variation]` result
    /// is delivered on the MainActor — consistent with every other completion overload.
    /// - Parameters:
    ///   - enableTracking: Forwarded to the async ``runExperiences(enableTracking:)``; defaults to `true`.
    ///   - completion: Invoked once on the MainActor with the bucketed variations (`[]` when the SDK
    ///     is not yet ready).
    func runExperiences(
        enableTracking: Bool = true,
        completion: @MainActor @escaping ([Variation]) -> Void
    ) {
        Task { @MainActor in completion(await self.runExperiences(enableTracking: enableTracking)) }
    }
}

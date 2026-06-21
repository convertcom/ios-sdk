// ConvertSwiftSDK+Completion.swift
// Completion-handler bridge for the async `ready()` (Epic 2 / Story 2).
// Completion-handler bridge for the async tracking-toggle API (Epic 5 / Story 5.6).
// For UIKit/Objective-C-style call sites that prefer a callback over `await`.

import Foundation

public extension ConvertSwiftSDK {
    /// Completion-handler overload of `ready()`. The result is delivered on the MainActor.
    /// - Parameter completion: Invoked once on the MainActor with `.success` when config
    ///   resolves (or is degraded), or `.failure` with the ``ConvertError`` on an
    ///   unrecoverable configuration error.
    func ready(completion: @escaping @MainActor (Result<Void, ConvertError>) -> Void) {
        Task {
            do {
                try await self.ready()
                await MainActor.run { completion(.success(())) }
            } catch let error as ConvertError {
                await MainActor.run { completion(.failure(error)) }
            } catch {
                // ready() only throws ConvertError; defensively map any other error.
                await MainActor.run { completion(.failure(.invalidConfiguration(String(describing: error)))) }
            }
        }
    }

    // MARK: - Runtime tracking toggle (Story 5.6)

    /// Completion-handler overload of ``setTrackingEnabled(_:)`` (Story 5.6). Delivers the
    /// completion on the MainActor once the actor-isolated flag is updated AND the value has
    /// been propagated to the production ``EventQueue``. Mirrors the `ready(completion:)` pattern.
    ///
    /// ```swift
    /// sdk.setTrackingEnabled(false) { /* called on MainActor when gate is closed */ }
    /// ```
    ///
    /// - Parameters:
    ///   - enabled: `true` to enable delivery; `false` to suppress.
    ///   - completion: Invoked once on the MainActor after the flag is set.
    func setTrackingEnabled(_ enabled: Bool, completion: @escaping @MainActor () -> Void) {
        Task {
            await self.setTrackingEnabled(enabled)
            await MainActor.run { completion() }
        }
    }

    /// Completion-handler overload of ``isTrackingEnabled()`` (Story 5.6). Delivers the current
    /// runtime tracking flag on the MainActor. Mirrors the `ready(completion:)` pattern.
    ///
    /// ```swift
    /// sdk.isTrackingEnabled { isOn in
    ///     print("tracking:", isOn)
    /// }
    /// ```
    ///
    /// - Parameter completion: Invoked once on the MainActor with the current tracking flag.
    func isTrackingEnabled(completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            let value = await self.isTrackingEnabled()
            await MainActor.run { completion(value) }
        }
    }
}

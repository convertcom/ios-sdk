// ConvertSDK+Completion.swift
// Completion-handler bridge for the async `ready()` (Epic 2 / Story 2).
// For UIKit/Objective-C-style call sites that prefer a callback over `await`.

import Foundation

public extension ConvertSDK {
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
}

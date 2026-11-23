//
//  HedgedAttempt.swift
//  Construct Messenger
//
//  One attempt, and a second beside it when the first stays silent.
//

import Foundation

/// Runs `attempt(0)`; if it has neither answered nor failed after `delay`, runs `attempt(1)` beside
/// it. The first success is returned, the other attempt is cancelled, and a success that arrives
/// anyway is handed to `discard`.
///
/// A failure before the second attempt started is the answer: this is for silence, not for retries.
/// After that, the call fails once both have, with the first error.
enum HedgedAttempt {
    private enum Step<T: Sendable>: Sendable {
        case silence
        case ended(Result<T, any Error>)
    }

    static func first<T: Sendable>(
        after delay: Duration,
        discard: @escaping @Sendable (T) -> Void,
        _ attempt: @escaping @Sendable (Int) async throws -> T
    ) async throws -> T {
        let outcome: Result<T, any Error> = await withTaskGroup(of: Step<T>.self) { group in
            let run: @Sendable (Int) async -> Step<T> = { index in
                do { return .ended(.success(try await attempt(index))) } catch { return .ended(.failure(error)) }
            }
            group.addTask { await run(0) }
            group.addTask {
                try? await Task.sleep(for: delay)
                return .silence
            }
            var winner: T?
            var firstError: (any Error)?
            var running = 1
            while let step = await group.next() {
                switch step {
                case .silence:
                    guard winner == nil, running > 0, !Task.isCancelled else { continue }
                    running += 1
                    group.addTask { await run(1) }
                case .ended(.success(let value)):
                    running -= 1
                    if winner == nil {
                        winner = value
                        group.cancelAll()
                    } else {
                        discard(value)
                    }
                case .ended(.failure(let error)):
                    running -= 1
                    firstError = firstError ?? error
                    if running == 0 { group.cancelAll() }
                }
            }
            if let winner { return .success(winner) }
            return .failure(firstError ?? CancellationError())
        }
        return try outcome.get()
    }
}

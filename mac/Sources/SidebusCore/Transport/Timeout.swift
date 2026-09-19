import Foundation

/// Bounds the duration of an asynchronous operation.
///
/// Essential when connecting: a tablet that is advertised but unreachable, the common case
/// on networks isolating their clients, returns nothing at all. Packets are dropped in
/// silence, no refusal arrives, and `NWConnection` waits forever.
/// - Parameter suspendedWhile: while this test answers true, the clock does not run.
///   It exists for the pairing dialog, which opens in the middle of the TLS handshake. The
///   time a user spends comparing two codes says nothing about whether the tablet is
///   reachable. Without this pause, pairing fails as soon as someone takes more than eight
///   seconds to answer, which happens the moment the tablet is in another room.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    suspendedWhile pause: (@Sendable () async -> Bool)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            guard let pause else {
                try await Task.sleep(for: duration)
                throw TransportError.timedOut
            }
            // Counted down in slices: a slice that elapses during a pause does not count.
            let tranche = Duration.milliseconds(200)
            var restant = duration
            while restant > .zero {
                try await Task.sleep(for: tranche)
                if await pause() { continue }
                restant -= tranche
            }
            throw TransportError.timedOut
        }

        guard let result = try await group.next() else {
            throw TransportError.timedOut
        }
        group.cancelAll()
        return result
    }
}

import Foundation

/// Borne la durée d'une opération asynchrone.
///
/// Indispensable pour la connexion : une tablette annoncée mais injoignable, cas courant
/// sur les réseaux qui isolent les clients entre eux, ne renvoie rien du tout. Les paquets
/// sont jetés en silence, aucun refus n'arrive, et `NWConnection` attend indéfiniment.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TransportError.timedOut
        }

        guard let result = try await group.next() else {
            throw TransportError.timedOut
        }
        group.cancelAll()
        return result
    }
}

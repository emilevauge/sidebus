import Foundation

/// Borne la durée d'une opération asynchrone.
///
/// Indispensable pour la connexion : une tablette annoncée mais injoignable, cas courant
/// sur les réseaux qui isolent les clients entre eux, ne renvoie rien du tout. Les paquets
/// sont jetés en silence, aucun refus n'arrive, et `NWConnection` attend indéfiniment.
/// - Parameter suspendedWhile: tant que ce test répond vrai, le chronomètre ne court pas.
///   Sert au dialogue d'appairage : il s'ouvre au milieu du handshake TLS, et le temps que
///   l'utilisateur compare les deux codes n'a rien à voir avec la joignabilité de la
///   tablette. Sans cette pause, l'appairage échoue dès qu'on met plus de huit secondes à
///   répondre, ce qui arrive dès qu'on doit aller chercher la tablette.
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
            // Décompte par tranches : une tranche écoulée pendant une pause ne compte pas.
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

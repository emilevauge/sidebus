import Foundation
import XCTest

@testable import SidebusCore

final class TimeoutTests: XCTestCase {

    func testRendLeResultatQuandCEstRapide() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testLeveQuandCaTraine() async {
        do {
            _ = try await withTimeout(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
            XCTFail("un dépassement était attendu")
        } catch let error as TransportError {
            guard case .timedOut = error else { return XCTFail("erreur inattendue : \(error)") }
        } catch {
            XCTFail("erreur inattendue : \(error)")
        }
    }

    /// Adresse qui ne répond jamais : ni acceptation, ni refus. C'est le comportement
    /// d'un réseau qui isole ses clients.
    func testConnexionVersUnTrouNoir() async {
        let started = Date()
        let client = TransportClient(host: "10.255.255.1", port: 27183, kind: .wifi)
        do {
            try await withTimeout(.seconds(2)) { try await client.connect() }
            XCTFail("la connexion ne devait pas aboutir")
        } catch {
            await client.close()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "le dépassement n'a pas coupé")
    }

    /// Le délai ne doit pas courir pendant qu'un dialogue attend une réponse humaine.
    /// Sans cette pause, l'appairage échoue dès qu'on met plus de huit secondes à
    /// comparer les deux codes.
    func testDelaiEnPausePendantUneQuestion() async throws {
        let enPause = Drapeau()
        await enPause.lever()

        let valeur = try await withTimeout(
            .milliseconds(300),
            suspendedWhile: { await enPause.estLeve() }
        ) {
            // Deux fois le délai, mais tout se passe pendant la pause.
            try await Task.sleep(for: .milliseconds(600))
            await enPause.baisser()
            return 42
        }

        XCTAssertEqual(valeur, 42)
    }

    /// La pause ne doit pas désarmer le délai pour toujours.
    func testDelaiRepartApresLaQuestion() async {
        let enPause = Drapeau()
        await enPause.lever()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await enPause.baisser()
        }

        do {
            _ = try await withTimeout(
                .milliseconds(300),
                suspendedWhile: { await enPause.estLeve() }
            ) {
                try await Task.sleep(for: .seconds(10))
                return 0
            }
            XCTFail("le délai aurait dû se déclencher")
        } catch TransportError.timedOut {
            // attendu
        } catch {
            XCTFail("erreur inattendue : \(error)")
        }
    }
}

private actor Drapeau {
    private var leve = false
    func lever() { leve = true }
    func baisser() { leve = false }
    func estLeve() -> Bool { leve }
}

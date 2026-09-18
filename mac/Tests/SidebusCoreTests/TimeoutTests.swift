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
}

import Foundation
import Network
import XCTest

@testable import SidebusCore

final class BonjourBrowserTests: XCTestCase {

    /// Publie un service témoin avec `dns-sd` et vérifie que le navigateur le voit avec
    /// ses enregistrements TXT.
    ///
    /// Désactivé par défaut : la découverte dépend du réseau de la machine, et le binaire
    /// de test n'est pas signé, donc l'autorisation Réseau local de macOS peut le bloquer.
    /// Lancer avec `SIDEBUS_BONJOUR=1 swift test --filter BonjourBrowserTests`.
    func testAnnonceLocaleDecouverte() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIDEBUS_BONJOUR"] == "1",
            "découverte désactivée, poser SIDEBUS_BONJOUR=1"
        )

        let deviceID = UUID()
        let serviceName = "Sidebus test \(Int.random(in: 1000...9999))"

        let publisher = Process()
        publisher.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        publisher.arguments = [
            "-R", serviceName, Sidebus.serviceType, "local", "\(Sidebus.port)",
            "v=1", "id=\(deviceID.uuidString)", "w=2560", "h=1600", "d=320", "c=3", "fp=0011223344556677",
        ]
        publisher.standardOutput = FileHandle.nullDevice
        publisher.standardError = FileHandle.nullDevice
        try publisher.run()
        defer { publisher.terminate() }

        let browser = BonjourBrowser()
        let peers = await browser.start()
        defer { Task { await browser.stop() } }

        var found: Peer?
        let deadline = Date().addingTimeInterval(15)

        outer: for await list in peers {
            for peer in list where peer.name == serviceName {
                found = peer
                break outer
            }
            if Date() > deadline { break }
        }

        let peer = try XCTUnwrap(found, "service témoin non découvert en 15 s")
        XCTAssertEqual(peer.kind, .wifi)
        XCTAssertEqual(peer.deviceID, deviceID, "identifiant du TXT mal lu")
        if case .service = peer.endpoint {} else {
            XCTFail("endpoint de service attendu, obtenu \(peer.endpoint)")
        }
    }
}

import AppKit
import Foundation
import Observation
import SidebusCore
import os

/// Applique le modèle `known_hosts` : une empreinte connue passe, une empreinte inconnue
/// demande confirmation à l'utilisateur, une empreinte qui change pour un appareil connu
/// est refusée.
@MainActor
@Observable
final class PairingValidator: CertificateValidator {

    /// Empreinte de la connexion en cours, pour la rattacher à l'identifiant de l'appareil
    /// dès que DEVICE_INFO l'apporte.
    private(set) var lastAcceptedFingerprint: Data?
    private(set) var lastRefusal: String?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "pairing")

    nonisolated init() {}

    /// Les accès au stockage se font hors du main actor : un dialogue système ouvert par
    /// le trousseau bloquerait sinon toute l'application au milieu du handshake.
    private func storeAccess<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool {
        if let expectedDeviceID,
            let known = await storeAccess({ PairingStore.shared.fingerprint(forDeviceID: expectedDeviceID) }) {
            guard known == fingerprint else {
                lastRefusal = """
                    L'empreinte de « \(expectedDeviceID) » a changé. Connexion refusée.
                    """
                log.error("empreinte différente pour \(expectedDeviceID, privacy: .public), refus")
                await showMismatch(deviceID: expectedDeviceID)
                return false
            }
            lastAcceptedFingerprint = fingerprint
            return true
        }

        // En USB, l'identifiant n'arrive qu'après le handshake : on reconnaît l'appareil
        // à son empreinte seule.
        if expectedDeviceID == nil, await storeAccess({ PairingStore.shared.isKnown(fingerprint) }) {
            lastAcceptedFingerprint = fingerprint
            return true
        }

        let accepted = await confirmPairing(code: PairingCode.code(for: fingerprint))
        guard accepted else {
            lastRefusal = "appairage refusé"
            return false
        }

        // L'identifiant réel remplacera cette clé provisoire dès DEVICE_INFO.
        let key = expectedDeviceID ?? Self.provisionalKey(for: fingerprint)
        do {
            try await storeAccess({ Result { try PairingStore.shared.save(fingerprint, forDeviceID: key) } }).get()
            lastAcceptedFingerprint = fingerprint
            lastRefusal = nil
            log.info("appareil appairé sous la clé \(key, privacy: .public)")
        } catch {
            lastRefusal = "enregistrement dans le trousseau impossible : \(error)"
            log.error("trousseau : \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// Rattache l'empreinte acceptée à l'identifiant réel de l'appareil, connu seulement
    /// après DEVICE_INFO.
    func bind(deviceID: UUID) {
        guard let fingerprint = lastAcceptedFingerprint else { return }
        let identifier = deviceID.uuidString

        if PairingStore.shared.fingerprint(forDeviceID: identifier) == fingerprint { return }

        let provisional = Self.provisionalKey(for: fingerprint)
        try? PairingStore.shared.save(fingerprint, forDeviceID: identifier)
        PairingStore.shared.remove(deviceID: provisional)
        log.info("empreinte rattachée à \(identifier, privacy: .public)")
    }

    private static func provisionalKey(for fingerprint: Data) -> String {
        "en-attente-" + fingerprint.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func confirmPairing(code: String) async -> Bool {
        // Crochet de développement, pour valider la chaîne sans intervention humaine.
        if ProcessInfo.processInfo.environment["SIDEBUS_AUTO_PAIR"] == "1" {
            log.info("appairage automatique (SIDEBUS_AUTO_PAIR), code \(code, privacy: .public)")
            return true
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Appairer cette tablette ?"
        alert.informativeText = """
            Code affiché sur la tablette : \(code)

            Vérifiez que les deux codes sont identiques avant de confirmer. S'ils diffèrent, \
            quelqu'un d'autre se fait passer pour votre tablette.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Appairer")
        alert.addButton(withTitle: "Refuser")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMismatch(deviceID: String) async {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Cette tablette ne présente plus le même certificat"
        alert.informativeText = """
            L'appareil « \(deviceID) » était appairé avec un autre certificat. La connexion \
            est refusée.

            Soit l'application a été réinstallée sur la tablette, soit quelqu'un se fait \
            passer pour elle. Pour réappairer volontairement, supprimez l'entrée du \
            trousseau nommée « app.sidebus.pairing ».
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Fermer")
        alert.runModal()
    }
}

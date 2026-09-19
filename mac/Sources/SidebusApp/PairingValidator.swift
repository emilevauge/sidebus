import AppKit
import Foundation
import Observation
import SidebusCore
import os

/// Applique le modèle `known_hosts` : une empreinte connue passe, une empreinte inconnue
/// demande confirmation à l'utilisateur, une empreinte qui change pour un appareil connu
/// est refusée.
///
/// L'appairage se fait en deux temps, et cette classe ne couvre que le premier. Elle
/// obtient l'accord de l'utilisateur du Mac pendant le handshake TLS, puisque c'est là
/// qu'apparaît l'empreinte, mais elle **n'enregistre rien**. L'enregistrement attend le
/// PAIR_RESULT de la tablette, donc l'accord de l'autre côté : c'est `DeviceSession` qui
/// appelle alors `commitPending`. Un appairage refusé d'un côté ne laisse ainsi aucune
/// trace de l'autre.
///
/// Une instance par session : l'empreinte en attente appartient à une connexion précise, et
/// deux tablettes peuvent s'appairer en même temps.
@MainActor
@Observable
final class PairingValidator: CertificateValidator {

    /// Empreinte acceptée côté Mac, en attente de la confirmation de la tablette.
    private(set) var pendingFingerprint: Data?
    private(set) var lastRefusal: String?

    /// Empreinte de la connexion en cours, déjà appairée ou non.
    private(set) var acceptedFingerprint: Data?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "pairing")

    nonisolated init() {}

    /// Vrai quand la tablette doit encore confirmer, par PAIR_REQUEST puis PAIR_RESULT.
    var awaitsRemoteConfirmation: Bool { pendingFingerprint != nil }

    /// Code à montrer aux deux bouts, dérivé de l'empreinte.
    var pendingCode: UInt32? {
        pendingFingerprint.map(PairingCode.value(for:))
    }

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
            acceptedFingerprint = fingerprint
            return true
        }

        // En USB, l'identifiant n'arrive qu'après le handshake : on reconnaît l'appareil
        // à son empreinte seule.
        if expectedDeviceID == nil, await storeAccess({ PairingStore.shared.isKnown(fingerprint) }) {
            acceptedFingerprint = fingerprint
            return true
        }

        let accepted = await confirmPairing(code: PairingCode.code(for: fingerprint))
        guard accepted else {
            lastRefusal = "appairage refusé sur le Mac"
            return false
        }

        // Rien n'est écrit ici : la tablette doit confirmer à son tour.
        pendingFingerprint = fingerprint
        acceptedFingerprint = fingerprint
        lastRefusal = nil
        return true
    }

    /// Enregistre l'empreinte, une fois les deux côtés d'accord.
    func commitPending(deviceID: UUID) throws {
        guard let fingerprint = pendingFingerprint else { return }
        try PairingStore.shared.save(fingerprint, forDeviceID: deviceID.uuidString)
        pendingFingerprint = nil
        log.info("appareil appairé sous \(deviceID.uuidString, privacy: .public)")
    }

    /// Abandonne l'appairage en cours : la tablette a refusé, ou n'a pas répondu.
    func discardPending(reason: String) {
        guard pendingFingerprint != nil else { return }
        pendingFingerprint = nil
        lastRefusal = reason
        log.info("appairage abandonné : \(reason, privacy: .public)")
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

            La tablette demandera ensuite sa propre confirmation.
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
            passer pour elle. Pour réappairer volontairement, désappairez l'appareil dans \
            les réglages de Sidebus.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Fermer")
        alert.runModal()
    }
}

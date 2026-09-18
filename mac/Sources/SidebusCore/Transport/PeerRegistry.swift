import Foundation

/// Réunit les tablettes vues en USB et en Wi-Fi, et tranche quand c'est la même.
///
/// L'USB gagne toujours : plus rapide, plus stable, et il recharge la tablette.
///
/// La difficulté tient à l'identité. En Wi-Fi, l'annonce mDNS porte l'identifiant
/// persistant de l'appareil. En USB, on ne connaît d'abord que le numéro de série adb, et
/// l'identifiant n'arrive qu'avec DEVICE_INFO. La correspondance apprise à la première
/// connexion est donc conservée, et c'est elle qui permet l'arbitrage ensuite.
public struct PeerRegistry: Sendable, Equatable {
    public var usbPeers: [Peer] = []
    public var wifiPeers: [Peer] = []

    /// Numéro de série adb vers identifiant d'appareil, appris à la connexion.
    public var serialToDevice: [String: UUID] = [:]

    public init(
        usbPeers: [Peer] = [],
        wifiPeers: [Peer] = [],
        serialToDevice: [String: UUID] = [:]
    ) {
        self.usbPeers = usbPeers
        self.wifiPeers = wifiPeers
        self.serialToDevice = serialToDevice
    }

    /// Une entrée par tablette. Les liens USB d'abord, puis les tablettes vues seulement
    /// en Wi-Fi.
    public func resolved() -> [Peer] {
        let usbDeviceIDs = Set(usbPeers.compactMap { serialToDevice[$0.id] })

        let wifiOnly = wifiPeers.filter { peer in
            guard let deviceID = peer.deviceID else { return true }
            return !usbDeviceIDs.contains(deviceID)
        }

        return usbPeers + wifiOnly
    }

    /// Tablette à privilégier, ou `nil` si aucune n'est visible.
    public func preferred() -> Peer? {
        resolved().first
    }

    /// Vrai si `candidate` doit remplacer le lien courant.
    ///
    /// On ne bascule que dans un sens, du Wi-Fi vers l'USB : l'inverse n'a lieu qu'à la
    /// disparition de l'USB, traitée comme une déconnexion.
    public func shouldSwitch(from current: Peer?, to candidate: Peer?) -> Bool {
        guard let candidate else { return false }
        guard let current else { return true }
        return current.kind == .wifi && candidate.kind == .usb
    }
}

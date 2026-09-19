import Foundation

/// Brings together the tablets seen on USB and on Wi-Fi, and decides when they are the
/// same one.
///
/// USB always wins: faster, steadier, and it charges the tablet.
///
/// The difficulty is identity. On Wi-Fi the mDNS advertisement carries the device's
/// persistent identifier. On USB all we know at first is the adb serial, and the identifier
/// only arrives with DEVICE_INFO. The mapping learned on the first connection is therefore
/// kept, and it is what makes the arbitration possible afterwards.
public struct PeerRegistry: Sendable, Equatable {
    public var usbPeers: [Peer] = []
    public var wifiPeers: [Peer] = []

    /// adb serial to device identifier, learned on connection.
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

    /// One entry per tablet. USB links first, then the tablets seen on Wi-Fi only.
    public func resolved() -> [Peer] {
        let usbDeviceIDs = Set(usbPeers.compactMap { serialToDevice[$0.id] })

        let wifiOnly = wifiPeers.filter { peer in
            guard let deviceID = peer.deviceID else { return true }
            return !usbDeviceIDs.contains(deviceID)
        }

        return usbPeers + wifiOnly
    }

    /// The tablet to prefer, or `nil` when none is visible.
    public func preferred() -> Peer? {
        resolved().first
    }

    /// True when `candidate` should replace the current link.
    ///
    /// Switching only goes one way, Wi-Fi to USB. The other way only happens when USB
    /// disappears, which is handled as a disconnection.
    public func shouldSwitch(from current: Peer?, to candidate: Peer?) -> Bool {
        guard let candidate else { return false }
        guard let current else { return true }
        return current.kind == .wifi && candidate.kind == .usb
    }
}

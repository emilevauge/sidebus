import Foundation

/// Accepts a device already paired, and only that: the phone's call channel never pairs,
/// it relies on a pairing made through the display server.
public struct KnownDeviceValidator: CertificateValidator {
    public init() {}

    public func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool {
        await Task.detached {
            if let expectedDeviceID {
                return PairingStore.shared.fingerprint(forDeviceID: expectedDeviceID) == fingerprint
            }
            return PairingStore.shared.isKnown(fingerprint)
        }.value
    }
}

import Foundation

/// The tokens phones granted this Mac for their calls (`protocol/PROTOCOL.md` 10.2), one
/// per device. Same storage as the fingerprints, under a service of its own: the data
/// protection keychain, or a file only the user can read when the keychain is unavailable.
public enum CallTokenStore {
    private static let store = PairingStore(service: "app.sidebus.calls")

    public static func token(forDeviceID deviceID: String) -> Data? {
        store.fingerprint(forDeviceID: deviceID)
    }

    public static func save(_ token: Data, forDeviceID deviceID: String) {
        try? store.save(token, forDeviceID: deviceID)
    }

    public static func remove(deviceID: String) {
        store.remove(deviceID: deviceID)
    }
}

import Foundation

/// Decides whether to accept the certificate a tablet presents.
///
/// Verification validates no chain of trust, there is none: it compares the fingerprint
/// with the recorded one, and asks the user for confirmation when the device is unknown.
public protocol CertificateValidator: Sendable {
    /// - Parameters:
    ///   - fingerprint: SHA-256 of the presented certificate.
    ///   - expectedDeviceID: the expected identifier when known in advance, that is on
    ///     Wi-Fi where it comes from the mDNS advertisement. `nil` on USB, where it only
    ///     arrives with DEVICE_INFO.
    func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool
}

/// Accepts everything. Tests only.
public struct AcceptAnyCertificate: CertificateValidator {
    public init() {}

    public func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool {
        true
    }
}

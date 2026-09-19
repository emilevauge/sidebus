import CryptoKit
import Foundation

/// Six digit code derived from a certificate fingerprint.
///
/// Both sides compute it the same way, described in `protocol/PROTOCOL.md` section 7. The
/// comparison that matters is visual: the user checks what the tablet shows against what
/// the Mac shows.
public enum PairingCode {

    public static func code(for fingerprint: Data) -> String {
        format(value(for: fingerprint))
    }

    /// The same code as a number: that is the form PAIR_REQUEST carries.
    public static func value(for fingerprint: Data) -> UInt32 {
        guard fingerprint.count >= 4 else { return 0 }
        let bytes = Array(fingerprint.prefix(4))
        let value = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return value % 1_000_000
    }

    /// Six digits, leading zeros included.
    public static func format(_ value: UInt32) -> String {
        String(format: "%06d", value)
    }

    /// SHA-256 fingerprint of a certificate in DER form.
    public static func fingerprint(ofDER der: Data) -> Data {
        Data(SHA256.hash(data: der))
    }

    /// Readable form, in byte pairs, for an alert message.
    public static func readable(_ fingerprint: Data) -> String {
        fingerprint.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }
}

import CryptoKit
import Foundation

/// Code à six chiffres dérivé de l'empreinte d'un certificat.
///
/// Les deux côtés le calculent de la même façon, décrite dans `protocol/PROTOCOL.md`
/// section 7. Il ne transite jamais sur le lien : l'utilisateur compare ce que montre la
/// tablette avec ce que montre le Mac.
public enum PairingCode {

    public static func code(for fingerprint: Data) -> String {
        format(value(for: fingerprint))
    }

    /// Le même code, en nombre : c'est sous cette forme qu'il part dans PAIR_REQUEST.
    public static func value(for fingerprint: Data) -> UInt32 {
        guard fingerprint.count >= 4 else { return 0 }
        let bytes = Array(fingerprint.prefix(4))
        let value = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return value % 1_000_000
    }

    /// Six chiffres, zéros de tête compris.
    public static func format(_ value: UInt32) -> String {
        String(format: "%06d", value)
    }

    /// Empreinte SHA-256 d'un certificat au format DER.
    public static func fingerprint(ofDER der: Data) -> Data {
        Data(SHA256.hash(data: der))
    }

    /// Forme lisible, par groupes de deux octets, pour un message d'alerte.
    public static func readable(_ fingerprint: Data) -> String {
        fingerprint.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }
}

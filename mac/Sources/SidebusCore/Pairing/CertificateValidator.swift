import Foundation

/// Décide d'accepter ou non le certificat présenté par une tablette.
///
/// La vérification ne valide aucune chaîne de confiance, il n'y en a pas : elle compare
/// l'empreinte à celle enregistrée, et demande confirmation à l'utilisateur quand
/// l'appareil est inconnu.
public protocol CertificateValidator: Sendable {
    /// - Parameters:
    ///   - fingerprint: SHA-256 du certificat présenté.
    ///   - expectedDeviceID: identifiant attendu quand il est connu d'avance, c'est à dire
    ///     en Wi-Fi où il vient de l'annonce mDNS. `nil` en USB, où il n'arrive qu'avec
    ///     DEVICE_INFO.
    func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool
}

/// Accepte tout. Réservé aux tests.
public struct AcceptAnyCertificate: CertificateValidator {
    public init() {}

    public func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool {
        true
    }
}

import Foundation

/// Constantes partagées avec le côté Android. Toute valeur ici est décrite dans
/// `protocol/PROTOCOL.md`, qui reste la source de vérité.
public enum Sidebus {
    /// Version du protocole implémentée par ce binaire.
    public static let protocolVersion: UInt16 = 1

    /// Port d'écoute de la tablette. Fixe, pour rester compatible avec `adb forward`.
    public static let port: UInt16 = 27183

    /// Type de service mDNS annoncé par la tablette.
    public static let serviceType = "_sidebus._tcp"
}

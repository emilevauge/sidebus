import Foundation

/// Ajuste le débit d'encodage d'après ce que la tablette rapporte.
///
/// Le signal utile est le taux de frames droppées : une tablette qui n'affiche pas tout ce
/// qu'elle reçoit est saturée, par le réseau ou par son décodeur. On baisse vite et on
/// remonte lentement, parce qu'une remontée trop rapide replonge aussitôt.
public struct BitrateController: Sendable {

    public struct Profile: Sendable {
        public let minimum: Int
        public let maximum: Int
        public let start: Int

        /// L'USB encaisse beaucoup, le Wi-Fi doit rester prudent.
        public static let usb = Profile(minimum: 4_000_000, maximum: 30_000_000, start: 15_000_000)
        public static let wifi = Profile(minimum: 2_000_000, maximum: 15_000_000, start: 8_000_000)

        public init(minimum: Int, maximum: Int, start: Int) {
            self.minimum = minimum
            self.maximum = maximum
            self.start = start
        }
    }

    public let profile: Profile
    public private(set) var bitrate: Int

    /// Fenêtres consécutives sans droppe, avant de retenter plus haut.
    private var calmWindows = 0

    public init(profile: Profile) {
        self.profile = profile
        self.bitrate = profile.start
    }

    /// Nouvelle mesure reçue de la tablette. Renvoie le débit à appliquer s'il change.
    @discardableResult
    public mutating func apply(received: UInt32, dropped: UInt32) -> Int? {
        let total = received + dropped
        guard total > 0 else { return nil }

        let dropRate = Double(dropped) / Double(total)
        let previous = bitrate

        if dropRate > 0.15 {
            // Saturation franche : on coupe fort, tout de suite.
            calmWindows = 0
            bitrate = max(profile.minimum, Int(Double(bitrate) * 0.6))
        } else if dropRate > 0.05 {
            calmWindows = 0
            bitrate = max(profile.minimum, Int(Double(bitrate) * 0.85))
        } else {
            calmWindows += 1
            // Trois fenêtres calmes, soit six secondes, avant de remonter de 10 %.
            if calmWindows >= 3 {
                calmWindows = 0
                bitrate = min(profile.maximum, Int(Double(bitrate) * 1.1))
            }
        }

        return bitrate == previous ? nil : bitrate
    }

    /// Cadence conseillée quand la tablette n'arrive pas à suivre même à débit plancher.
    /// C'est le signe d'un décodeur saturé ou d'un throttling thermique, pas du réseau.
    public func suggestedFrameRate(current: Int, received: UInt32, dropped: UInt32) -> Int? {
        let total = received + dropped
        guard total > 0 else { return nil }
        let dropRate = Double(dropped) / Double(total)

        if dropRate > 0.25, bitrate <= profile.minimum, current > 30 {
            return 30
        }
        if dropRate < 0.02, current < 60 {
            return 60
        }
        return nil
    }
}

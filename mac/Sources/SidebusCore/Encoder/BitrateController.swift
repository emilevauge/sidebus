import Foundation

/// Adjusts the encoding bitrate from what the tablet reports.
///
/// The useful signal is the dropped frame rate: a tablet that does not display everything
/// it receives is saturated, by the network or by its decoder. Cut fast and climb back
/// slowly, because climbing too fast dives straight back down.
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

    /// Consecutive windows with no drop, before trying higher again.
    private var calmWindows = 0

    public init(profile: Profile) {
        self.profile = profile
        self.bitrate = profile.start
    }

    /// A fresh measurement from the tablet. Returns the bitrate to apply when it changes.
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
            // Three quiet windows, six seconds, before climbing back by 10 %.
            if calmWindows >= 3 {
                calmWindows = 0
                bitrate = min(profile.maximum, Int(Double(bitrate) * 1.1))
            }
        }

        return bitrate == previous ? nil : bitrate
    }

    /// Suggested frame rate when the tablet cannot keep up even at the floor bitrate. That
    /// points at a saturated decoder or thermal throttling, not at the network.
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

import Foundation

/// Constants shared with the Android side. Every value here is described in
/// `protocol/PROTOCOL.md`, which stays the source of truth.
public enum Sidebus {
    /// Protocol version implemented by this binary.
    public static let protocolVersion: UInt16 = 1

    /// Port the tablet listens on. Fixed, so that `adb forward` keeps working.
    public static let port: UInt16 = 27183

    /// mDNS service type advertised by the tablet.
    public static let serviceType = "_sidebus._tcp"

    /// How long a question put to a human may hold everything else up.
    ///
    /// Not in the protocol: the protocol only bounds PAIR_RESULT, at 120 s. This bounds the
    /// Mac's own dialog, which nothing else limits. Long enough to fetch the tablet from
    /// another room, short enough that a prompt left on a locked screen does not hold a
    /// socket open all night.
    public static let humanAnswerDeadline = Duration.seconds(300)
}

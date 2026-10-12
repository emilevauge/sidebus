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

    /// A phone's call channel: its port and its mDNS service type, section 10.
    public static let callPort: UInt16 = 27185
    public static let callServiceType = "_sidebus-call._tcp"
}

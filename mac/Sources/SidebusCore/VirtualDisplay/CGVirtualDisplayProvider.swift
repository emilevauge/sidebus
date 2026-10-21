import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import os

/// Creates a real virtual display, on demand, at the tablet's dimensions.
///
/// That is what this adds over the DeskPad harness: the display matches the tablet's panel
/// exactly, instead of a resolution fixed in advance.
///
/// The display is created on connection and destroyed on disconnection. A ghost display
/// that lingers with no tablet attached disturbs the window layout, and that is the main
/// complaint aimed at tools of this kind.
///
/// The classes involved are private: everything goes through `VirtualDisplayProvider`, and
/// an initialisation failure is detected explicitly so we can fall back to an existing
/// display.
public actor CGVirtualDisplayProvider: VirtualDisplayProvider {

    public struct Configuration: Sendable {
        /// Dimensions en pixels de la dalle de la tablette.
        public var width: Int
        public var height: Int
        /// Density announced by the tablet, in dpi.
        public var density: Int
        public var refreshRate: Double
        public var name: String
        /// Serial number the display shows macOS. The same one on every connection of a
        /// tablet lets macOS recognize the display: it puts it back where the user arranged
        /// it, and its windows with it. `nil` draws a new one.
        public var serialNumber: UInt32?

        public init(
            width: Int,
            height: Int,
            density: Int,
            refreshRate: Double = 60,
            name: String = "Sidebus",
            serialNumber: UInt32? = nil
        ) {
            self.width = width
            self.height = height
            self.density = density
            self.refreshRate = refreshRate
            self.name = name
            self.serialNumber = serialNumber
        }

        /// A tablet's serial number, drawn from its persistent identifier. Never 0, which
        /// macOS reads as no serial at all.
        public static func serialNumber(for device: UUID) -> UInt32 {
            let bytes = withUnsafeBytes(of: device.uuid) { Array($0) }
            var hash: UInt32 = 2_166_136_261
            for byte in bytes {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
            return hash == 0 ? 1 : hash
        }

        /// Physical size to declare in order to land on the wanted density.
        ///
        /// macOS derives the density from the physical size and the pixel count. Getting it
        /// wrong here yields an interface that is either minuscule or enormous.
        public var sizeInMillimeters: CGSize {
            let dpi = max(Double(density), 72)
            let millimetersPerInch = 25.4
            return CGSize(
                width: Double(width) / dpi * millimetersPerInch,
                height: Double(height) / dpi * millimetersPerInch
            )
        }

        /// Logical dimensions of the HiDPI mode. The tablet being dense, we show at 2x.
        public var pointSize: (width: Int, height: Int) {
            density >= 200 ? (width / 2, height / 2) : (width, height)
        }
    }

    public enum VirtualDisplayError: Error, CustomStringConvertible, Sendable {
        case unavailable
        case creationFailed
        case settingsRefused

        public var description: String {
            switch self {
            case .unavailable:
                return "the virtual display API does not exist on this version of macOS"
            case .creationFailed:
                return "cannot create the virtual display"
            case .settingsRefused:
                return "the virtual display refused the requested configuration"
            }
        }
    }

    private let configuration: Configuration
    private var display: CGVirtualDisplay?
    private let log = Logger(subsystem: "app.sidebus", category: "virtual-display")

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// True when the private classes are present. Check before attempting creation, so the
    /// fallback stays clean.
    public static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
    }

    public func acquire() async throws -> CGDirectDisplayID {
        if let display { return display.displayID }
        guard Self.isSupported else { throw VirtualDisplayError.unavailable }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue(label: "app.sidebus.virtual-display")
        descriptor.name = configuration.name
        descriptor.maxPixelsWide = UInt32(configuration.width)
        descriptor.maxPixelsHigh = UInt32(configuration.height)
        descriptor.sizeInMillimeters = configuration.sizeInMillimeters
        descriptor.productID = Self.productID
        descriptor.vendorID = Self.vendorID
        descriptor.serialNum = await serialNumber()
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let (pointWidth, pointHeight) = configuration.pointSize
        let settings = CGVirtualDisplaySettings()
        // A HiDPI mode is declared in points; `hiDPI = 1` doubles the pixels.
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt32(pointWidth),
                height: UInt32(pointHeight),
                refreshRate: configuration.refreshRate
            )
        ]
        settings.hiDPI = configuration.pointSize.width == configuration.width ? 0 : 1

        guard display.apply(settings) else {
            throw VirtualDisplayError.settingsRefused
        }
        guard display.displayID != 0 else {
            throw VirtualDisplayError.creationFailed
        }

        // The display does offer a HiDPI mode, but macOS defaults to the one with the most
        // points, so 1x. On a dense panel the interface would be minuscule, so we pick the
        // 2x mode ourselves.
        selectHiDPIMode(for: display.displayID)

        self.display = display
        log.notice(
            """
            virtual display \(display.displayID) created at \(pointWidth)×\(pointHeight) points, \
            \(self.configuration.width)×\(self.configuration.height) pixels, serial \
            \(descriptor.serialNum), Sidebus displays online: \(Self.onlineDisplays().count)
            """
        )
        return display.displayID
    }

    private static let vendorID: UInt32 = 0x5342  // "SB"
    private static let productID: UInt32 = 0x1234

    /// Every Sidebus display macOS lists right now, this process's or not.
    static func onlineDisplays() -> [(id: CGDirectDisplayID, serial: UInt32)] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            .filter { CGDisplayVendorNumber($0) == vendorID && CGDisplayModelNumber($0) == productID }
            .map { ($0, CGDisplaySerialNumber($0)) }
    }

    /// The tablet's own serial, once the display that last carried it is gone. The removal
    /// of a released display takes macOS a moment, and two displays with one serial get
    /// mixed up: after two seconds, a fresh serial instead, the arrangement lost for once.
    private func serialNumber() async -> UInt32 {
        guard let wanted = configuration.serialNumber else { return UInt32.random(in: 1...UInt32.max) }
        for _ in 0..<20 {
            guard Self.onlineDisplays().contains(where: { $0.serial == wanted }) else { return wanted }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.error("a display still holds serial \(wanted), drawing a fresh one")
        return UInt32.random(in: 1...UInt32.max)
    }

    /// Switches the display to its 2x mode, when it offers one at the right definition.
    private func selectHiDPIMode(for id: CGDirectDisplayID) {
        guard configuration.pointSize.width != configuration.width else { return }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return
        }

        let target = modes.first {
            $0.pixelWidth == configuration.width
                && $0.pixelHeight == configuration.height
                && $0.width * 2 == $0.pixelWidth
        }
        guard let target else {
            log.error("no HiDPI mode offered by the virtual display, showing at 1x")
            return
        }

        var handle: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&handle) == .success else { return }
        CGConfigureDisplayWithDisplayMode(handle, id, target, nil)
        // `forSession`: the display is ephemeral, no need to write a lasting preference.
        CGCompleteDisplayConfiguration(handle, .forSession)
    }

    public func release() async {
        guard let display else { return }
        log.notice("virtual display \(display.displayID) removed")
        // Releasing the object removes the display, and macOS then restores the user's window
        // layout.
        self.display = nil
    }
}

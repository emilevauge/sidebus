import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import os

/// Crée un vrai écran virtuel, à la demande, aux dimensions de la tablette.
///
/// C'est la valeur ajoutée par rapport au harnais DeskPad : l'écran épouse exactement la
/// dalle de la tablette au lieu d'une résolution fixée d'avance.
///
/// L'écran est créé à la connexion et détruit à la déconnexion. Un écran fantôme qui
/// persiste sans tablette branchée dérange l'agencement des fenêtres, c'est le reproche
/// principal fait à ce genre d'outil.
///
/// Les classes utilisées sont privées : tout passe par `VirtualDisplayProvider`, et
/// l'échec d'initialisation est détecté explicitement pour basculer sur un écran existant.
public actor CGVirtualDisplayProvider: VirtualDisplayProvider {

    public struct Configuration: Sendable {
        /// Dimensions en pixels de la dalle de la tablette.
        public var width: Int
        public var height: Int
        /// Densité annoncée par la tablette, en dpi.
        public var density: Int
        public var refreshRate: Double
        public var name: String

        public init(
            width: Int,
            height: Int,
            density: Int,
            refreshRate: Double = 60,
            name: String = "Sidebus"
        ) {
            self.width = width
            self.height = height
            self.density = density
            self.refreshRate = refreshRate
            self.name = name
        }

        /// Taille physique à déclarer pour obtenir la densité voulue.
        ///
        /// macOS déduit la densité de la taille physique et du nombre de pixels. Se
        /// tromper ici donne une interface soit minuscule, soit énorme.
        public var sizeInMillimeters: CGSize {
            let dpi = max(Double(density), 72)
            let millimetersPerInch = 25.4
            return CGSize(
                width: Double(width) / dpi * millimetersPerInch,
                height: Double(height) / dpi * millimetersPerInch
            )
        }

        /// Dimensions logiques du mode HiDPI. La tablette étant dense, on affiche en 2x.
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
                return "l'API d'écran virtuel n'existe pas sur cette version de macOS"
            case .creationFailed:
                return "création de l'écran virtuel impossible"
            case .settingsRefused:
                return "l'écran virtuel a refusé la configuration demandée"
            }
        }
    }

    private let configuration: Configuration
    private var display: CGVirtualDisplay?
    private let log = Logger(subsystem: "app.sidebus", category: "virtual-display")

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Vrai si les classes privées sont présentes. À vérifier avant de tenter la création,
    /// pour pouvoir basculer proprement.
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
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x5342  // "SB"
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let (pointWidth, pointHeight) = configuration.pointSize
        let settings = CGVirtualDisplaySettings()
        // Un mode HiDPI se déclare en points ; `hiDPI = 1` fait doubler les pixels.
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

        // L'écran propose bien un mode HiDPI, mais macOS retient par défaut celui qui a
        // le plus de points, donc le 1x. Sur une dalle dense, l'interface serait
        // minuscule : on sélectionne le mode 2x nous mêmes.
        selectHiDPIMode(for: display.displayID)

        self.display = display
        log.info(
            """
            écran virtuel \(display.displayID) créé en \(pointWidth)×\(pointHeight) points, \
            \(self.configuration.width)×\(self.configuration.height) pixels
            """
        )
        return display.displayID
    }

    /// Bascule l'écran sur son mode 2x, s'il en propose un à la bonne définition.
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
            log.error("aucun mode HiDPI offert par l'écran virtuel, affichage en 1x")
            return
        }

        var handle: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&handle) == .success else { return }
        CGConfigureDisplayWithDisplayMode(handle, id, target, nil)
        // `forSession` : l'écran est éphémère, inutile d'écrire une préférence durable.
        CGCompleteDisplayConfiguration(handle, .forSession)
    }

    public func release() async {
        guard let display else { return }
        log.info("écran virtuel \(display.displayID) retiré")
        // Le relâchement de l'objet retire l'écran : macOS restaure alors l'agencement
        // des fenêtres de l'utilisateur.
        self.display = nil
    }
}

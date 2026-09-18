import AppKit
import CoreGraphics
import Observation
import SidebusCore

/// État du sélecteur d'écran du menu bar.
@MainActor
@Observable
final class DisplayMenuModel {
    private(set) var displays: [DisplayInfo] = []
    private(set) var lastError: String?

    /// Clé de persistance du choix d'écran, relue par `UsbConnectionModel`.
    static let selectedDisplayKey = "selectedDisplayID"

    /// Écran que Sidebus capturera. `nil` tant que rien n'est choisi.
    var selectedID: CGDirectDisplayID? {
        didSet {
            if let selectedID {
                UserDefaults.standard.set(Int(selectedID), forKey: Self.selectedDisplayKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedDisplayKey)
            }
        }
    }

    // `nonisolated(unsafe)` pour pouvoir retirer l.observateur dans `deinit`, qui n.est
    // pas isolé. Écrit une seule fois, depuis `init` sur le main actor.
    @ObservationIgnored
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    init() {
        refresh()
        startAutomaticCaptureIfRequested()

        // macOS poste cette notification au branchement, au débranchement et à tout
        // changement de résolution, y compris quand DeskPad crée ou retire son écran.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func refresh() {
        do {
            displays = try DisplayEnumerator.activeDisplays()
            lastError = nil
        } catch {
            displays = []
            lastError = String(describing: error)
        }

        // L'écran choisi a pu disparaître, DeskPad quitté par exemple.
        if let selectedID, !displays.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// Fournisseur correspondant à la sélection courante.
    var selectedProvider: (any VirtualDisplayProvider)? {
        selectedID.map { ExistingDisplayProvider(targetID: $0) }
    }

    // MARK: - Capture

    /// Sortie temporaire de la phase 2, relue avec `ffplay`.
    static let outputPath = "/tmp/sidebus.h264"

    private(set) var isCapturing = false
    private(set) var frameCount = 0
    private(set) var byteCount = 0

    @ObservationIgnored
    private let session = CaptureSession()
    @ObservationIgnored
    private var consumer: Task<Void, Never>?

    var captureLabel: String {
        guard isCapturing else { return "Démarrer la capture" }
        let megabytes = Double(byteCount) / 1_000_000
        return String(format: "Arrêter la capture (%d frames, %.1f Mo)", frameCount, megabytes)
    }

    func toggleCapture() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    /// Crochets de développement, pour mesurer sans passer par le menu.
    ///
    /// - `SIDEBUS_AUTOCAPTURE` : fragment du nom de l'écran à capturer au lancement.
    /// - `SIDEBUS_CAPTURE_SCALE` : facteur appliqué à la taille de capture, 1.0 par défaut.
    /// - `SIDEBUS_FPS` : plafond d'images par seconde, 60 par défaut.
    private func startAutomaticCaptureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let needle = environment["SIDEBUS_AUTOCAPTURE"], !needle.isEmpty else { return }
        guard let display = displays.first(
            where: { $0.name.localizedCaseInsensitiveContains(needle) }
        ) else {
            lastError = "aucun écran dont le nom contient « \(needle) »"
            return
        }
        selectedID = display.id
        startCapture()
        devLog("autocapture sur \(display.menuLabel), erreur=\(lastError ?? "aucune")")
    }

    /// Trace de développement, active uniquement sous `SIDEBUS_AUTOCAPTURE`.
    private func devLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["SIDEBUS_AUTOCAPTURE"] != nil else { return }
        let line = "\(Date()) \(message)\n"
        let path = "/tmp/sidebus-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func startCapture() {
        guard let display = displays.first(where: { $0.id == selectedID }) else {
            lastError = "choisir un écran avant de démarrer la capture"
            return
        }
        guard ScreenCapturer.isAuthorized() else {
            ScreenCapturer.requestAuthorization()
            lastError = String(describing: CaptureError.screenRecordingNotAuthorized)
            return
        }

        lastError = nil
        frameCount = 0
        byteCount = 0
        isCapturing = true

        let environment = ProcessInfo.processInfo.environment
        let scale = environment["SIDEBUS_CAPTURE_SCALE"].flatMap(Double.init) ?? 1.0
        let fps = environment["SIDEBUS_FPS"].flatMap(Int.init) ?? 60

        let provider = ExistingDisplayProvider(targetID: display.id)
        // La mise à l'échelle se fait dans ScreenCaptureKit, côté GPU.
        let pixelSize = CGSize(
            width: (display.pixelSize.width * scale).rounded(),
            height: (display.pixelSize.height * scale).rounded()
        )
        let path = Self.outputPath

        consumer = Task { [session] in
            do {
                let writer = try H264FileWriter(path: path)
                let frames = try await session.start(
                    provider: provider,
                    pixelSize: pixelSize,
                    fps: fps
                )
                var frames0 = 0
                var bytes0 = 0
                for await frame in frames {
                    await writer.write(frame)
                    frames0 += 1
                    bytes0 += frame.data.count + (frame.parameterSets?.count ?? 0)
                    // Les compteurs sont observés par SwiftUI : les toucher à chaque frame
                    // réveille l'AttributeGraph 60 fois par seconde pour un menu fermé.
                    if frames0 % 15 == 0 {
                        frameCount = frames0
                        byteCount = bytes0
                    }
                }
                frameCount = frames0
                byteCount = bytes0
                await writer.close()
            } catch {
                lastError = String(describing: error)
            }
            isCapturing = false
        }
    }

    private func stopCapture() {
        consumer?.cancel()
        consumer = nil
        let session = self.session
        Task {
            await session.stop()
        }
        isCapturing = false
    }
}

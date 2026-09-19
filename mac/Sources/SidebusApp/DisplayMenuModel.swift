import AppKit
import CoreGraphics
import Observation
import SidebusCore

/// State of the display picker.
@MainActor
@Observable
final class DisplayMenuModel {
    private(set) var displays: [DisplayInfo] = []
    private(set) var lastError: String?

    /// Persistence key for the display choice, read back by `DeviceSession`.
    static let selectedDisplayKey = "selectedDisplayID"

    /// Display Sidebus will capture. `nil` while nothing is chosen.
    var selectedID: CGDirectDisplayID? {
        didSet {
            if let selectedID {
                UserDefaults.standard.set(Int(selectedID), forKey: Self.selectedDisplayKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedDisplayKey)
            }
        }
    }

    // `nonisolated(unsafe)` so the observer can be removed in `deinit`, which is not
    // isolated. Written once, from `init` on the main actor.
    @ObservationIgnored
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    init() {
        refresh()
        startAutomaticCaptureIfRequested()

        // macOS posts this notification on plug, unplug and any resolution change, including
        // when DeskPad creates or removes its display.
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

        // The chosen display may have gone, DeskPad quit for instance.
        if let selectedID, !displays.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// Provider matching the current selection.
    var selectedProvider: (any VirtualDisplayProvider)? {
        selectedID.map { ExistingDisplayProvider(targetID: $0) }
    }

    // MARK: - Capture

    /// Temporary phase 2 output, played back with `ffplay`.
    static let outputPath = "/tmp/sidebus.h264"

    private(set) var isCapturing = false
    private(set) var frameCount = 0
    private(set) var byteCount = 0

    @ObservationIgnored
    private let session = CaptureSession()
    @ObservationIgnored
    private var consumer: Task<Void, Never>?

    var captureLabel: String {
        // Local recording, not to be confused with sharing to the tablet.
        guard isCapturing else { return "Record the stream to a file" }
        let megabytes = Double(byteCount) / 1_000_000
        return String(
            format: "Stop recording (%d frames, %.1f MB)",
            frameCount,
            megabytes
        )
    }

    func toggleCapture() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    /// Development hooks, to measure without going through the settings.
    ///
    /// - `SIDEBUS_AUTOCAPTURE`: fragment of the name of the display to capture at launch.
    /// - `SIDEBUS_CAPTURE_SCALE`: factor applied to the capture size, 1.0 by default.
    /// - `SIDEBUS_FPS`: frames per second ceiling, 60 by default.
    private func startAutomaticCaptureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let needle = environment["SIDEBUS_AUTOCAPTURE"], !needle.isEmpty else { return }
        guard let display = displays.first(
            where: { $0.name.localizedCaseInsensitiveContains(needle) }
        ) else {
            lastError = "no display whose name contains \"\(needle)\""
            return
        }
        selectedID = display.id
        startCapture()
        devLog("autocapture sur \(display.menuLabel), erreur=\(lastError ?? "aucune")")
    }

    /// Development trace, active under `SIDEBUS_AUTOCAPTURE` only.
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
            lastError = "pick a display before starting the capture"
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
        // Scaling happens inside ScreenCaptureKit, on the GPU.
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
                    // The counters are observed by SwiftUI: touching them on every frame wakes
                    // the AttributeGraph 60 times a second for a closed menu.
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

import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Capture un écran avec ScreenCaptureKit et livre les frames en flux asynchrone.
public actor ScreenCapturer {

    /// Autorisation Enregistrement de l'écran. `request` ouvre la fenêtre système la
    /// première fois, et ne fait rien ensuite : elle ne prend effet qu'après relance.
    public static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private let sampleQueue = DispatchQueue(label: "app.sidebus.capture", qos: .userInteractive)

    public init() {}

    /// Démarre la capture de `displayID` et renvoie le flux de frames.
    ///
    /// - Parameters:
    ///   - displayID: écran à capturer, fourni par un `VirtualDisplayProvider`.
    ///   - pixelSize: taille de capture, en pixels natifs.
    ///   - fps: plafond d'images par seconde. ScreenCaptureKit ne livre une frame que
    ///     lorsque le contenu change, donc un écran statique coûte zéro.
    public func start(
        displayID: CGDirectDisplayID,
        pixelSize: CGSize,
        fps: Int = 60
    ) async throws -> AsyncStream<CapturedFrame> {
        guard Self.isAuthorized() else {
            throw CaptureError.screenRecordingNotAuthorized
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotShareable(displayID)
        }

        await stop()

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        // Format natif de l'encodeur : pas de conversion d'espace couleur en route.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Bas, pour la latence : une file profonde ne sert qu'à accumuler du retard.
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(3)
        )
        self.continuation = continuation

        let delegate = StreamDelegate(continuation: continuation)
        let output = FrameOutput(continuation: continuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)

        // Le délégué et la sortie ne sont retenus par personne d'autre.
        continuation.onTermination = { _ in
            _ = (delegate, output)
        }

        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
        return frames
    }

    /// Change le plafond de cadence sans interrompre la capture.
    public func setFrameRate(_ fps: Int) async {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? await stream.updateConfiguration(configuration)
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        configuration = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Reçoit les samples sur la file de ScreenCaptureKit et les pousse dans le flux.
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    init(continuation: AsyncStream<CapturedFrame>.Continuation) {
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Seules les frames `complete` portent des pixels neufs. `idle` signale un écran
        // inchangé, `blank` un écran vide : les deux se jettent.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status == .complete
        else { return }

        // Rectangles modifiés : une frame qui n'en a aucun ne montre rien de neuf.
        // L'encoder coûterait du CPU et du débit pour une image identique.
        if let rects = attachments.first?[.dirtyRects] as? [Any], rects.isEmpty {
            return
        }

        guard let imageBuffer = sampleBuffer.imageBuffer else { return }

        continuation.yield(
            CapturedFrame(
                imageBuffer: imageBuffer,
                presentationTime: sampleBuffer.presentationTimeStamp
            )
        )
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    init(continuation: AsyncStream<CapturedFrame>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish()
    }
}

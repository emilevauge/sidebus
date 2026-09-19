import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

let captureLog = Logger(subsystem: "app.sidebus", category: "capture")

/// Captures a display with ScreenCaptureKit and delivers frames as an async stream.
public actor ScreenCapturer {

    /// Screen Recording permission. `request` opens the system window the first time and
    /// does nothing afterwards: it only takes effect after a restart.
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

    /// Starts capturing `displayID` and returns the frame stream.
    ///
    /// - Parameters:
    ///   - displayID: display to capture, supplied by a `VirtualDisplayProvider`.
    ///   - pixelSize: taille de capture, en pixels natifs.
    ///   - fps: plafond d'images par seconde. ScreenCaptureKit ne livre une frame que
    ///     when the content changes, so a static screen costs nothing.
    public func start(
        displayID: CGDirectDisplayID,
        pixelSize: CGSize,
        fps: Int = 60
    ) async throws -> AsyncStream<CapturedFrame> {
        guard Self.isAuthorized() else {
            throw CaptureError.screenRecordingNotAuthorized
        }

        // A freshly created virtual display does not show up in the shareable content right
        // away: the system takes a few hundred milliseconds to publish it. Retry rather
        // than fail on a race.
        var display: SCDisplay?
        for attempt in 0..<6 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            if let found = content.displays.first(where: { $0.displayID == displayID }) {
                display = found
                break
            }
            if attempt == 0 || attempt == 5 {
                let ids = content.displays.map { String($0.displayID) }.joined(separator: ", ")
                captureLog.info(
                    "display \(displayID) not shareable, offered displays: [\(ids, privacy: .public)]"
                )
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        guard let display else {
            throw CaptureError.displayNotShareable(displayID)
        }

        await stop()

        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        // Format natif de l'encodeur : pas de conversion d'espace couleur en route.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Low, for latency: a deep queue only accumulates lag.
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

        // Nobody else retains the delegate and the output.
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

/// Receives samples on ScreenCaptureKit's queue and pushes them into the stream.
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

        // Only `complete` frames carry fresh pixels. `idle` means an unchanged screen,
        // `blank` an empty one: both are dropped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status == .complete
        else { return }

        // Dirty rectangles: a frame with none shows nothing new. Encoding it would cost CPU
        // and bitrate for an identical picture.
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
        captureLog.info("stream stopped: \(String(describing: error), privacy: .public)")
        continuation.finish()
    }
}

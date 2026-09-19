import CoreGraphics
import CoreMedia
import Foundation

/// The full capture to encode chain: acquires the display from a
/// `VirtualDisplayProvider`, branche ScreenCaptureKit sur VideoToolbox, et livre les
/// encoded frames.
///
/// En phase 2 la sortie part dans un fichier. En phase 3 elle partira sur le socket,
/// sans rien changer ici.
public actor CaptureSession {

    /// Size of the stream to send: the captured display fitted into the tablet's panel
    /// without distorting or enlarging. Dimensions are even, since the encoder works in
    /// macroblocs.
    public static func streamSize(display: CGSize, device: CGSize) -> CGSize {
        guard display.width > 0, display.height > 0 else { return device }

        let scale = min(
            device.width / display.width,
            device.height / display.height,
            1
        )
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = (value * scale).rounded()
            return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
        }
        return CGSize(width: even(display.width), height: even(display.height))
    }

    private let capturer = ScreenCapturer()
    private var provider: (any VirtualDisplayProvider)?
    private var encoder: VideoEncoder?
    private var pump: Task<Void, Never>?
    /// Last captured frame, kept so that a keyframe request can be answered even when the
    /// screen has stopped moving.
    private var lastFrame: CapturedFrame?

    public init() {}

    public func start(
        provider: any VirtualDisplayProvider,
        pixelSize: CGSize,
        fps: Int = 60,
        bitrate: Int = 15_000_000,
        codec: Codec = .h264
    ) async throws -> AsyncStream<EncodedFrame> {
        await stop()

        let displayID = try await provider.acquire()
        let encoder = try VideoEncoder(
            configuration: VideoEncoderConfiguration(
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                fps: fps,
                bitrate: bitrate,
                codec: codec
            )
        )
        let captured = try await capturer.start(
            displayID: displayID,
            pixelSize: pixelSize,
            fps: fps
        )

        self.provider = provider
        self.encoder = encoder
        pump = Task {
            for await frame in captured {
                await self.remember(frame)
                do {
                    try await encoder.encode(frame)
                } catch {
                    break
                }
            }

            // Capture stopped, for instance because macOS cut the share.
            // Terminer l'encodeur propage la nouvelle au consommateur, qui attendrait
            // sinon des frames qui ne viendront plus.
            await encoder.finish()
        }

        return encoder.frames
    }

    /// Adjusts the target bitrate without interrupting capture.
    public func setBitrate(_ bitrate: Int) async {
        await encoder?.setBitrate(bitrate)
    }

    public func currentBitrate() async -> Int? {
        await encoder?.bitrate
    }

    /// Change le plafond de cadence, sans interrompre la capture.
    public func setFrameRate(_ fps: Int) async {
        await capturer.setFrameRate(fps)
    }

    private func remember(_ frame: CapturedFrame) {
        lastFrame = frame
    }

    /// Forces a keyframe, in answer to KEYFRAME_REQ.
    ///
    /// ScreenCaptureKit only delivers a frame when the content changes. On a still
    /// immobile, se contenter d'armer le drapeau laisserait la tablette corrompue jusqu'au
    /// next movement. So the last known frame is re-encoded right away.
    public func requestKeyframe() async {
        guard let encoder else { return }
        await encoder.requestKeyframe()

        guard let lastFrame else { return }
        let refreshed = CapturedFrame(
            imageBuffer: lastFrame.imageBuffer,
            // VideoToolbox exige des horodatages strictement croissants.
            presentationTime: CMTimeAdd(
                lastFrame.presentationTime,
                CMTime(value: 1, timescale: 1000)
            )
        )
        self.lastFrame = refreshed
        try? await encoder.encode(refreshed)
    }

    public func stop() async {
        pump?.cancel()
        pump = nil
        await capturer.stop()
        await encoder?.finish()
        encoder = nil
        await provider?.release()
        provider = nil
    }
}

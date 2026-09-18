import CoreGraphics
import Foundation

/// Chaîne complète capture vers encodage : acquiert l'écran auprès d'un
/// `VirtualDisplayProvider`, branche ScreenCaptureKit sur VideoToolbox, et livre les
/// frames encodées.
///
/// En phase 2 la sortie part dans un fichier. En phase 3 elle partira sur le socket,
/// sans rien changer ici.
public actor CaptureSession {

    /// Taille du flux à envoyer : l'écran capturé, ramené dans la dalle de la tablette
    /// sans déformer ni agrandir. Les dimensions sont paires, l'encodeur travaillant par
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
                do {
                    try await encoder.encode(frame)
                } catch {
                    break
                }
            }
        }

        return encoder.frames
    }

    /// Ajuste le débit visé sans interrompre la capture.
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

    /// Force une keyframe, en réponse à KEYFRAME_REQ.
    public func requestKeyframe() async {
        await encoder?.requestKeyframe()
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

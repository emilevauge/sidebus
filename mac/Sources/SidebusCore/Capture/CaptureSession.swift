import CoreGraphics
import CoreMedia
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
    /// Dernière frame capturée, conservée pour pouvoir répondre à une demande de keyframe
    /// même quand l'écran ne bouge plus.
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

            // La capture s'est arrêtée, par exemple parce que macOS a coupé le partage.
            // Terminer l'encodeur propage la nouvelle au consommateur, qui attendrait
            // sinon des frames qui ne viendront plus.
            await encoder.finish()
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

    private func remember(_ frame: CapturedFrame) {
        lastFrame = frame
    }

    /// Force une keyframe, en réponse à KEYFRAME_REQ.
    ///
    /// ScreenCaptureKit ne livre une frame que lorsque le contenu change. Sur un écran
    /// immobile, se contenter d'armer le drapeau laisserait la tablette corrompue jusqu'au
    /// prochain mouvement. On réencode donc tout de suite la dernière frame connue.
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

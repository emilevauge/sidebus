import CoreMedia
import CoreVideo
import Foundation

/// Une frame sortie de ScreenCaptureKit, prête à encoder.
///
/// Le `CVImageBuffer` est adossé à un `IOSurface` en mémoire GPU. Il est passé tel quel à
/// VideoToolbox : aucune copie, aucun accès aux pixels depuis le CPU.
///
/// `@unchecked Sendable` parce que `CVImageBuffer` est un type CoreFoundation que le
/// compilateur ne sait pas vérifier. Le buffer n'est ni muté ni partagé, il traverse le
/// pipeline en lecture seule.
public struct CapturedFrame: @unchecked Sendable {
    public let imageBuffer: CVImageBuffer
    public let presentationTime: CMTime

    public init(imageBuffer: CVImageBuffer, presentationTime: CMTime) {
        self.imageBuffer = imageBuffer
        self.presentationTime = presentationTime
    }

    public var pixelSize: CGSize {
        CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }
}

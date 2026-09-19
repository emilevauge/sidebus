import CoreMedia
import CoreVideo
import Foundation

/// A frame out of ScreenCaptureKit, ready to encode.
///
/// The `CVImageBuffer` is backed by an `IOSurface` in GPU memory. It goes to VideoToolbox
/// as is: no copy, no pixel access from the CPU.
///
/// `@unchecked Sendable` parce que `CVImageBuffer` est un type CoreFoundation que le
/// compiler cannot check. The buffer is neither mutated nor shared, it crosses the
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

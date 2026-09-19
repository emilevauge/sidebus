import CoreMedia
import Foundation

/// An encoded frame, in Annex B, ready to go out in a VIDEO_FRAME.
public struct EncodedFrame: Sendable {
    /// NAL units of the frame, separated by the start code.
    public let data: Data

    public let isKeyframe: Bool

    public let presentationTime: CMTime

    /// SPS and PPS in Annex B, present only when the format description changes: first
    /// frame, then any encoder reconfiguration. Feeds VIDEO_CONFIG.
    public let parameterSets: Data?

    public init(data: Data, isKeyframe: Bool, presentationTime: CMTime, parameterSets: Data?) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.presentationTime = presentationTime
        self.parameterSets = parameterSets
    }
}

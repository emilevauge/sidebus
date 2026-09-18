import CoreMedia
import Foundation

/// Une frame encodée, en Annex B, prête à partir dans un VIDEO_FRAME.
public struct EncodedFrame: Sendable {
    /// NAL units de la frame, séparées par le code de départ.
    public let data: Data

    public let isKeyframe: Bool

    public let presentationTime: CMTime

    /// SPS et PPS en Annex B, présents uniquement quand la description de format change :
    /// première frame, puis toute reconfiguration de l'encodeur. Alimente VIDEO_CONFIG.
    public let parameterSets: Data?

    public init(data: Data, isKeyframe: Bool, presentationTime: CMTime, parameterSets: Data?) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.presentationTime = presentationTime
        self.parameterSets = parameterSets
    }
}

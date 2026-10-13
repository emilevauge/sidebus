import Foundation

/// Readies the microphone for a narrowband call. The phone mixes the Mac's voice into the
/// call at telephone bandwidth (300 to 3400 Hz), so what lies outside only takes room:
/// cut the rumble, lift the band that carries the consonants, and even out the loud and
/// the quiet with a compressor, as telephone headsets do.
public struct VoiceShaper: Sendable {
    private var highPass: Biquad
    private var presence: Biquad
    private var envelope: Float = 0
    private let attack: Float
    private let release: Float

    // Above the threshold, each 3 dB louder comes out 1 dB louder; the makeup gain then
    // lifts the whole. Below the threshold the gain stays fixed, so silences keep their
    // level rather than being pulled up.
    private static let thresholdDB: Float = -28
    private static let ratio: Float = 3
    private static let makeupDB: Float = 8

    public init(sampleRate: Double) {
        let rate = Float(sampleRate)
        highPass = .highPass(frequency: 150, q: 0.707, sampleRate: rate)
        presence = .peak(frequency: 2500, q: 0.9, gainDB: 5, sampleRate: rate)
        attack = 1 - exp(-1 / (0.005 * rate))
        release = 1 - exp(-1 / (0.15 * rate))
    }

    /// Shapes 16 bit little endian mono PCM in place.
    public mutating func process(_ pcm: inout Data) {
        let count = pcm.count / 2
        guard count > 0 else { return }
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                let x = presence.process(highPass.process(Float(Int16(littleEndian: samples[index])) / 32768))
                let level = abs(x)
                envelope += (level > envelope ? attack : release) * (level - envelope)
                let levelDB = 20 * log10(max(envelope, 1e-6))
                let over = levelDB - Self.thresholdDB
                let gainDB = Self.makeupDB - (over > 0 ? over * (1 - 1 / Self.ratio) : 0)
                var y = x * pow(10, gainDB / 20)
                // Soft limit: what still peaks rounds off below full scale instead of clipping.
                if abs(y) > 0.7 { y = (y < 0 ? -1 : 1) * (0.7 + 0.25 * tanh((abs(y) - 0.7) / 0.25)) }
                samples[index] = Int16(clamping: Int((y * 32767).rounded())).littleEndian
            }
        }
    }
}

/// A second order filter, from Robert Bristow-Johnson's cookbook.
struct Biquad: Sendable {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    static func highPass(frequency: Float, q: Float, sampleRate: Float) -> Biquad {
        let w = 2 * Float.pi * frequency / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peak(frequency: Float, q: Float, gainDB: Float, sampleRate: Float) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

import Foundation

/// Readies the microphone for a narrowband call. The phone mixes the Mac's voice into the
/// call at telephone bandwidth (300 to 3400 Hz), so what lies outside only takes room:
/// cut the rumble, lift the band that carries the consonants, and hold the level steady,
/// as telephone headsets do.
public struct VoiceShaper: Sendable {
    private var highPass: Biquad
    private var presence: Biquad
    private var gain: Float = 1
    private var envelope: Float = 0
    private let sampleRate: Float

    // Speech is brought towards this level, by at most maxGain; below the gate, the room's
    // noise, the gain stops moving rather than lifting it.
    private static let targetRMS: Float = 0.12 // about -18 dBFS
    private static let maxGain: Float = 8 // +18 dB
    private static let gate: Float = 0.004 // about -48 dBFS

    public init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        highPass = .highPass(frequency: 150, q: 0.707, sampleRate: Float(sampleRate))
        presence = .peak(frequency: 2500, q: 0.9, gainDB: 5, sampleRate: Float(sampleRate))
    }

    /// Shapes 16 bit little endian mono PCM in place.
    public mutating func process(_ pcm: inout Data) {
        let count = pcm.count / 2
        guard count > 0 else { return }
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            // Envelope: fast to rise, slow to fall, so syllables do not pump.
            let attack = 1 - exp(-1 / (0.01 * sampleRate))
            let release = 1 - exp(-1 / (0.3 * sampleRate))
            let glide = 1 - exp(-1 / (0.15 * sampleRate))
            for index in 0..<count {
                var x = Float(Int16(littleEndian: samples[index])) / 32768
                x = presence.process(highPass.process(x))
                let level = abs(x)
                envelope += (level > envelope ? attack : release) * (level - envelope)
                if envelope > Self.gate {
                    // The envelope of a sine sits near 0.64 of its peak, its RMS near 0.71.
                    let wanted = min(Self.maxGain, Self.targetRMS / (envelope * 1.1))
                    gain += glide * (wanted - gain)
                }
                var y = x * gain
                // Soft limit: peaks round off instead of clipping.
                if abs(y) > 0.7 { y = (y < 0 ? -1 : 1) * (0.7 + 0.3 * tanh((abs(y) - 0.7) / 0.3)) }
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

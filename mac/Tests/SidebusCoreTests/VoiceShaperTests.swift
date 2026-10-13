import XCTest

@testable import SidebusCore

final class VoiceShaperTests: XCTestCase {

    private func tone(_ frequency: Double, amplitude: Double, seconds: Double = 1) -> Data {
        var data = Data()
        for index in 0..<Int(16000 * seconds) {
            let value = Int16(amplitude * 32767 * sin(2 * .pi * frequency * Double(index) / 16000))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func rms(_ data: Data, lastSeconds: Double = 0.25) -> Double {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let tail = samples.suffix(Int(16000 * lastSeconds)).map { Double($0) / 32768 }
        return (tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count)).squareRoot()
    }

    private func shaped(_ amplitude: Double) -> Double {
        var shaper = VoiceShaper(sampleRate: 16000)
        var data = tone(1000, amplitude: amplitude)
        shaper.process(&data)
        return rms(data)
    }

    func testLiftsQuietSpeechByTheMakeupGain() {
        // -34 dBFS stays below the threshold: only the makeup gain, +8 dB, applies.
        XCTAssertEqual(20 * log10(shaped(0.02) / (0.02 / 2.0.squareRoot())), 8, accuracy: 1)
    }

    func testNarrowsTheGapBetweenLoudAndQuiet() {
        // 20 dB apart going in, much less coming out.
        XCTAssertLessThan(20 * log10(shaped(0.5) / shaped(0.05)), 10)
    }

    func testTheHighPassCutsTheRumbleAndKeepsTheVoice() {
        func gain(_ frequency: Double) -> Double {
            var filter = Biquad.highPass(frequency: 150, q: 0.707, sampleRate: 16000)
            var peak: Float = 0
            for index in 0..<16000 {
                let y = filter.process(Float(sin(2 * .pi * frequency * Double(index) / 16000)))
                if index > 8000 { peak = max(peak, abs(y)) }
            }
            return Double(peak)
        }
        XCTAssertLessThan(gain(50), 0.15)
        XCTAssertGreaterThan(gain(1000), 0.95)
    }

    func testNeverClips() {
        var shaper = VoiceShaper(sampleRate: 16000)
        var data = tone(2500, amplitude: 1)
        shaper.process(&data)
        let peak = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        XCTAssertLessThan(peak, 32767)
    }
}

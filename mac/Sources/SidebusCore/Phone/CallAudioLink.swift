@preconcurrency import AVFoundation
import Foundation
import os

/// Mac half of a call's audio: plays what the phone sends (the other party) and hands the
/// microphone back, both as 16 kHz mono 16 bit little endian PCM. [PhoneChannel] carries
/// them; this class only deals with sound.
///
/// The microphone goes through macOS voice processing, so the speakers do not echo into
/// the call. One instance carries one call.
public final class CallAudioLink: @unchecked Sendable {
    private static let sampleRate = 16000.0
    private static let frameBytes = Int(sampleRate) / 50 * 2
    // Beyond this much audio waiting to play, incoming frames are dropped to keep the
    // delay down rather than letting it grow for the rest of the call.
    private static let maxQueuedMs = 200
    // Audio held back before playing starts, and again after running dry: frames
    // arrive in bursts, and playing each one as it lands leaves gaps that click.
    private static let prebufferMs = 80

    private let send: @Sendable (Data) -> Void
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private let queue = DispatchQueue(label: "app.sidebus.call-audio")
    private let log = Logger(subsystem: "app.sidebus", category: "phone")

    // Touched on `queue` only.
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var queuedFrames = 0
    private var buffering = true
    private var stopped = false
    private var muted = false

    /// `send` receives the microphone, in 20 ms or so pieces, on a background queue.
    public init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    /// Starts the audio engine. Needs the microphone permission; throws when the engine
    /// cannot start.
    public func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let micFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: micFormat, to: wireFormat)
        // With voice processing on, channel 0 carries the processed voice; the other
        // channels are not meant to be mixed in.
        converter?.channelMap = [0]
        queue.sync { self.converter = converter }
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        try engine.start()
        player.play()
    }

    public func stop() {
        queue.sync { stopped = true }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// Sends silence instead of the microphone, while true.
    public func setMuted(_ muted: Bool) {
        queue.async { self.muted = muted }
    }

    /// Plays a piece of the other party's voice.
    public func play(_ data: Data) {
        queue.async {
            guard !self.stopped else { return }
            self.pending.append(data)
            self.playPending()
        }
    }

    // MARK: Audio

    private func playPending() {
        let framesPerChunk = AVAudioFrameCount(Self.frameBytes / 2)
        if buffering {
            guard pending.count >= Int(Self.sampleRate) * Self.prebufferMs / 1000 * 2 else { return }
            buffering = false
        }
        while pending.count >= Self.frameBytes {
            let chunk = pending.prefix(Self.frameBytes)
            pending.removeFirst(Self.frameBytes)
            if queuedFrames * 1000 / Int(Self.sampleRate) > Self.maxQueuedMs { continue }

            let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: framesPerChunk)!
            buffer.frameLength = framesPerChunk
            let samples = buffer.floatChannelData![0]
            chunk.withUnsafeBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                for i in 0..<Int(framesPerChunk) { samples[i] = Float(Int16(littleEndian: ints[i])) / 32768 }
            }
            queuedFrames += Int(framesPerChunk)
            player.scheduleBuffer(buffer) { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.queuedFrames -= Int(framesPerChunk)
                    if self.queuedFrames == 0 { self.buffering = true }
                }
            }
        }
    }

    // Called on the audio tap's thread.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter = queue.sync(execute: { self.converter }) else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        var data = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
        queue.async { [self] in
            guard !stopped else { return }
            if muted { data.resetBytes(in: 0..<data.count) }
            send(data)
        }
    }
}

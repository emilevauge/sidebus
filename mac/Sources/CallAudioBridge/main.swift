// Mac half of the call audio bridge. The phone half is CallAudioProbe's stream mode,
// in android/callaudioprobe, which run.sh forwards to tcp:27183 here.
//
// Both directions are 16 kHz mono 16 bit little endian PCM, in 20 ms frames. What
// arrives is the other party's voice and goes to the speakers; the microphone goes
// back, through macOS voice processing so the speakers do not echo into the call.
//
//   swift run CallAudioBridge

import AVFoundation
import Foundation
import Network

let port: NWEndpoint.Port = 27183
let sampleRate = 16000.0
let frameBytes = Int(sampleRate) / 50 * 2
// Beyond this much audio waiting to play, incoming frames are dropped to keep the
// delay down rather than letting it grow for the rest of the call.
let maxQueuedMs = 200

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(stamp)] \(message)")
}

final class Bridge {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "bridge")

    // Touched on `queue` only.
    private var connection: NWConnection?
    private var pending = Data()
    private var queuedFrames = 0
    private var received = 0
    private var sent = 0
    private var dropped = 0

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let micFormat = input.outputFormat(forBus: 0)
        log("microphone: \(micFormat)")
        converter = AVAudioConverter(from: micFormat, to: wireFormat)
        // With voice processing on, channel 0 carries the processed voice; the other
        // channels are not meant to be mixed in.
        converter?.channelMap = [0]
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            self?.send(buffer)
        }

        try engine.start()
        player.play()
        connect()

        queue.asyncAfter(deadline: .now() + 2, execute: report)
    }

    // MARK: Network

    private func connect() {
        queue.async { [self] in
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            self.connection = connection
            pending.removeAll()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    log("connected to the phone")
                    receive(on: connection)
                case .failed, .cancelled:
                    retry(connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // adb accepts the TCP connection even when nothing listens on the phone, then
    // closes it: that case lands here too, and simply tries again.
    private func retry(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        self.connection = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                received += data.count
                pending.append(data)
                playPending()
            }
            if complete || error != nil {
                if received > 0 { log("phone closed the stream") }
                connection.cancel()
                return
            }
            receive(on: connection)
        }
    }

    // MARK: Audio

    private func playPending() {
        let framesPerChunk = AVAudioFrameCount(frameBytes / 2)
        while pending.count >= frameBytes {
            let chunk = pending.prefix(frameBytes)
            pending.removeFirst(frameBytes)

            if queuedFrames * 1000 / Int(sampleRate) > maxQueuedMs {
                dropped += 1
                continue
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: framesPerChunk)!
            buffer.frameLength = framesPerChunk
            let samples = buffer.floatChannelData![0]
            chunk.withUnsafeBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                for i in 0..<Int(framesPerChunk) { samples[i] = Float(Int16(littleEndian: ints[i])) / 32768 }
            }
            queuedFrames += Int(framesPerChunk)
            player.scheduleBuffer(buffer) { [weak self] in
                self?.queue.async { self?.queuedFrames -= Int(framesPerChunk) }
            }
        }
    }

    // Called on the audio tap's thread.
    private func send(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 16
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
        let data = Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
        queue.async { [self] in
            guard let connection, connection.state == .ready else { return }
            sent += data.count
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func report() {
        if connection?.state == .ready {
            let queuedMs = queuedFrames * 1000 / Int(sampleRate)
            log("in \(received / 1024) kB, out \(sent / 1024) kB, queued \(queuedMs) ms, dropped \(dropped) frames")
        }
        queue.asyncAfter(deadline: .now() + 2, execute: report)
    }
}

// Line buffered, so the log shows up live when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let bridge = Bridge()
do {
    try bridge.start()
} catch {
    log("audio engine: \(error)")
    exit(1)
}
log("waiting for the phone on port \(port)")
RunLoop.main.run()

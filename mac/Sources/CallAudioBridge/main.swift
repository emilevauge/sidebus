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
// Audio held back before playing starts, and again after running dry: frames
// arrive in bursts, and playing each one as it lands leaves gaps that click.
let prebufferMs = 80

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
    // SIDEBUS_DUMP=<path> keeps the received downlink, raw, to listen to it apart.
    private let dump = ProcessInfo.processInfo.environment["SIDEBUS_DUMP"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    private var underruns = 0
    private var buffering = true
    private var micSum: Double = 0
    private var micSamples = 0

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let micFormat = input.outputFormat(forBus: 0)
        log("microphone: \(inputDeviceName()) \(micFormat)")
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
                dump?.write(data)
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
        if buffering {
            guard pending.count >= Int(sampleRate) * prebufferMs / 1000 * 2 else { return }
            buffering = false
        }
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
                self?.queue.async {
                    guard let self else { return }
                    self.queuedFrames -= Int(framesPerChunk)
                    if self.queuedFrames == 0 {
                        self.underruns += 1
                        self.buffering = true
                    }
                }
            }
        }
    }

    // SIDEBUS_TONE=1 sends a 440 Hz tone instead of the microphone, to check the
    // uplink without anyone speaking.
    private let tone = ProcessInfo.processInfo.environment["SIDEBUS_TONE"] == "1"
    private var tonePhase = 0

    // Called on the audio tap's thread.
    private func send(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        if tone {
            let frames = Int(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate)
            var samples = [Int16](repeating: 0, count: frames)
            for i in 0..<frames {
                samples[i] = Int16(sin(2 * Double.pi * 440 * Double(tonePhase) / sampleRate) * 8000)
                tonePhase += 1
            }
            let data = samples.withUnsafeBytes { Data($0) }
            let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            queue.async { [self] in
                micSum += sum
                micSamples += frames
                guard let connection, connection.state == .ready else { return }
                sent += data.count
                connection.send(content: data, completion: .idempotent)
            }
            return
        }
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
        var sum: Double = 0
        let samples = output.int16ChannelData![0]
        for i in 0..<Int(output.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
        let count = Int(output.frameLength)
        queue.async { [self] in
            micSum += sum
            micSamples += count
            guard let connection, connection.state == .ready else { return }
            sent += data.count
            connection.send(content: data, completion: .idempotent)
        }
    }

    private func report() {
        if connection?.state == .ready {
            let queuedMs = queuedFrames * 1000 / Int(sampleRate)
            let micRms = micSamples == 0 ? 0 : Int((micSum / Double(micSamples)).squareRoot())
            micSum = 0
            micSamples = 0
            log("in \(received / 1024) kB, out \(sent / 1024) kB, mic rms \(micRms), queued \(queuedMs) ms, underruns \(underruns), dropped \(dropped) frames")
        }
        queue.asyncAfter(deadline: .now() + 2, execute: report)
    }
}

// Line buffered, so the log shows up live when piped.
setvbuf(stdout, nil, _IOLBF, 0)

// The system default input, which AVAudioEngine's input node follows.
func inputDeviceName() -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    address.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else {
        return "#\(device)"
    }
    return name.takeRetainedValue() as String
}

let bridge = Bridge()
do {
    try bridge.start()
} catch {
    log("audio engine: \(error)")
    exit(1)
}
log("waiting for the phone on port \(port)")
RunLoop.main.run()

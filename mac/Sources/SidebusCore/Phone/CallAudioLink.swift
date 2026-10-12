@preconcurrency import AVFoundation
import CoreAudio
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
    private var captureEngine = AVAudioEngine()
    private var playbackEngine = AVAudioEngine()
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
        borrowInput()
        do {
            try startWithVoiceProcessing()
            // Voice processing takes the built-in microphone in place of any aggregate.
            let input = Self.defaultInput().flatMap { Self.transportType($0) == kAudioDeviceTransportTypeAggregate ? nil : $0 }
                ?? Self.inputDevices().first { Self.transportType($0) == kAudioDeviceTransportTypeBuiltIn }
            route = Route(
                microphone: input.map(Self.name) ?? "?",
                speaker: Self.defaultOutput().map(Self.name) ?? "?",
                echoCancellation: true)
        } catch {
            // macOS sometimes refuses voice processing altogether (-10875), as when the
            // default input is an aggregate missing a member. A call with some echo beats
            // no call.
            log.error("voice processing unavailable, going without: \(String(describing: error), privacy: .public)")
            stopEngines()
            captureEngine = AVAudioEngine()
            playbackEngine = AVAudioEngine()
            try startPlain()
            route = Route(
                microphone: Self.microphone().map(Self.name) ?? "?",
                speaker: Self.defaultOutput().map(Self.name) ?? "?",
                echoCancellation: false)
        }
    }

    /// One engine for both directions, so that voice processing hears what the speakers
    /// play and takes it out of the microphone. It follows the system's default devices.
    private func startWithVoiceProcessing() throws {
        try captureEngine.inputNode.setVoiceProcessingEnabled(true)
        playbackEngine = captureEngine
        try startEngines()
    }

    /// Two engines: on macOS an engine's input and output share one device unit, so the
    /// microphone can only be chosen on an engine that plays nothing.
    private func startPlain() throws {
        if let device = Self.microphone() {
            try captureEngine.inputNode.auAudioUnit.setDeviceID(device)
        }
        try startEngines()
    }

    private func startEngines() throws {
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: playFormat)

        let input = captureEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: micFormat, to: wireFormat)
        // With voice processing on, channel 0 carries the processed voice; the other
        // channels are not meant to be mixed in.
        converter?.channelMap = [0]
        queue.sync { self.converter = converter }
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            self?.encode(buffer)
        }

        try captureEngine.start()
        if playbackEngine !== captureEngine { try playbackEngine.start() }
        player.play()
    }

    public func stop() {
        queue.sync { stopped = true }
        stopEngines()
        returnInput()
    }

    /// The devices the call's sound actually goes through, set once started.
    public private(set) var route: Route?

    public struct Route: Sendable, Equatable {
        public let microphone: String
        public let speaker: String
        public let echoCancellation: Bool
    }

    /// Default input set aside for the call, put back when it ends.
    private var setAsideInput: AudioDeviceID?

    /// Voice processing builds on the default input, and fails (-10875) when that is an
    /// aggregate missing a member, a USB microphone unplugged say. The call then borrows
    /// the built-in microphone as the default input.
    private func borrowInput() {
        guard let current = Self.defaultInput(),
              Self.isIncompleteAggregate(current),
              let builtIn = Self.inputDevices().first(where: { Self.transportType($0) == kAudioDeviceTransportTypeBuiltIn }),
              Self.setDefaultInput(builtIn)
        else { return }
        setAsideInput = current
        log.info("default input set to the built-in microphone for the call")
    }

    private func returnInput() {
        guard let input = setAsideInput else { return }
        setAsideInput = nil
        _ = Self.setDefaultInput(input)
    }

    /// An aggregate device some of whose members are not connected.
    static func isIncompleteAggregate(_ device: AudioDeviceID) -> Bool {
        guard transportType(device) == kAudioDeviceTransportTypeAggregate else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &list) == noErr,
              let uids = list?.takeRetainedValue() as? [String] else { return false }
        return uids.contains { uid in
            var translate = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cfUID = uid as CFString
            var found = AudioDeviceID(0)
            var foundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &translate,
                    UInt32(MemoryLayout<CFString>.size), pointer, &foundSize, &found)
            }
            return status != noErr || found == 0
        }
    }

    private static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    private func stopEngines() {
        captureEngine.inputNode.removeTap(onBus: 0)
        player.stop()
        captureEngine.stop()
        playbackEngine.stop()
        if player.engine != nil { playbackEngine.detach(player) }
    }

    /// The system's default input, unless it is an aggregate missing a member. The
    /// built-in microphone then.
    static func microphone() -> AudioDeviceID? {
        if let device = defaultInput(), !isIncompleteAggregate(device) {
            return device
        }
        return inputDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    private static func defaultInput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &device),
              device != 0 else { return nil }
        return device
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != 0 else { return nil }
        return device
    }

    private static func name(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else {
            return "#\(device)"
        }
        return name.takeRetainedValue() as String
    }

    private static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize)
            return streamsSize > 0
        }
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        _ = property(device, kAudioDevicePropertyTransportType, &value)
        return value
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
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
    private func encode(_ buffer: AVAudioPCMBuffer) {
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

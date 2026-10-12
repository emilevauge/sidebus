// Answers one question before any phone call work goes into Sidebus: does macOS still
// let a Mac act as a Bluetooth hands-free unit (HFP) for an Android phone, audio
// included? IOBluetoothHandsFreeDevice is in the SDK and not deprecated, but nobody
// here has seen it run on a current system.
//
//   swift run HandsFreeProbe list              paired devices, phones marked
//   swift run HandsFreeProbe <address>         connect, then type commands
//   swift run HandsFreeProbe <address> <channel>   same, on that RFCOMM channel
//
// The channel override exists because a Xiaomi 15 on HyperOS (Android 16) advertises
// its hands-free gateway on RFCOMM channel 1 in SDP, while the server actually listens
// on channel 8: channel 1 is refused, channel 8 answers AT+BRSF.
//
// The phone must already be paired with the Mac, from System Settings > Bluetooth.

import CoreAudio
import Foundation
import IOBluetooth

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(stamp)] \(message)")
}

// MARK: - Bluetooth

final class Probe: NSObject, IOBluetoothHandsFreeDeviceDelegate {
    private let handsFree: IOBluetoothHandsFreeDevice

    init(device: IOBluetoothDevice) {
        handsFree = IOBluetoothHandsFreeDevice(device: device, delegate: nil)
        super.init()
        handsFree.delegate = self
    }

    func start() {
        log("connecting to \(handsFree.device.nameOrAddress ?? "?")")
        handsFree.connect()
    }

    func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "dial": handsFree.dialNumber(argument)
        case "accept": handsFree.acceptCall()
        case "end": handsFree.endCall()
        case "dtmf": handsFree.sendDTMF(argument)
        case "mac": handsFree.transferAudioToComputer()
        case "phone": handsFree.transferAudioToPhone()
        case "sco": handsFree.connectSCO()
        case "calls": handsFree.currentCallList()
        case "at": handsFree.send(atCommand: argument)
        case "state": printState()
        case "audio": AudioDevices.print()
        case "quit":
            handsFree.disconnect()
            exit(0)
        default:
            print("""
                dial <number> | accept | end | dtmf <digit>
                mac | phone | sco      move the call audio, or open SCO by hand
                calls | at <command> | state | audio | quit
                """)
        }
    }

    private func printState() {
        log("""
            connected=\(handsFree.isConnected) sco=\(handsFree.isSCOConnected()) \
            features=0x\(String(handsFree.deviceSupportedFeatures, radix: 16)) \
            holdModes=0x\(String(handsFree.deviceCallHoldModes, radix: 16))
            """)
    }

    // IOBluetoothHandsFreeDelegate

    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        log("service level connection: status \(status.intValue)")
        printState()
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        log("disconnected: status \(status.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        log("SCO opened: status \(status.intValue)")
        // The question the probe exists for: does an audio device show up?
        AudioDevices.print()
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        log("SCO closed: status \(status.intValue)")
    }

    // IOBluetoothHandsFreeDeviceDelegate

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable value: NSNumber!) {
        log("service available: \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive value: NSNumber!) {
        log("call active: \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode value: NSNumber!) {
        log("call setup: \(value.intValue) (0 none, 1 incoming, 2 dialing, 3 ringing)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callHoldState value: NSNumber!) {
        log("call hold: \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        log("incoming call from \(number ?? "unknown")")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt value: NSNumber!) {
        log("ring \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall call: [AnyHashable: Any]!) {
        log("current call: \(call ?? [:])")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, signalStrength value: NSNumber!) {
        log("signal: \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, batteryCharge value: NSNumber!) {
        log("battery: \(value.intValue)")
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode code: String!) {
        log("unhandled: \(code ?? "")")
    }
}

// MARK: - Core Audio

enum AudioDevices {
    static func print() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)

        log("audio devices:")
        for id in ids {
            let input = channels(id, kAudioObjectPropertyScopeInput)
            let output = channels(id, kAudioObjectPropertyScopeOutput)
            Swift.print("    \(name(id)) [\(transport(id))] in=\(input) out=\(output)")
        }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return "#\(id)" }
        return name.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        switch value {
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth LE"
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeUSB: return "usb"
        default: return "other"
        }
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Channel override

// IOBluetoothHandsFree reads the channel from the gateway's SDP record and offers no way
// to pass another one, so the record's getter is swapped for one that lies about it.
nonisolated(unsafe) var channelOverride: BluetoothRFCOMMChannelID?

extension IOBluetoothSDPServiceRecord {
    @objc func probe_getRFCOMMChannelID(_ channel: UnsafeMutablePointer<BluetoothRFCOMMChannelID>) -> IOReturn {
        // Swapped: this calls the original.
        let result = probe_getRFCOMMChannelID(channel)
        let gateway = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassHandsFreeAudioGateway.rawValue))
        if let channelOverride, hasService(from: [gateway as Any]) {
            log("gateway record says channel \(channel.pointee), using \(channelOverride)")
            channel.pointee = channelOverride
        }
        return result
    }

    static func overrideGatewayChannel(_ channel: BluetoothRFCOMMChannelID) {
        channelOverride = channel
        let original = class_getInstanceMethod(self, #selector(getRFCOMMChannelID(_:)))!
        let swapped = class_getInstanceMethod(self, #selector(probe_getRFCOMMChannelID(_:)))!
        method_exchangeImplementations(original, swapped)
    }
}

// MARK: - Entry point

let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
let arguments = CommandLine.arguments.dropFirst()

guard let target = arguments.first, target != "list" else {
    for device in paired {
        let mark = device.isHandsFreeAudioGateway ? "phone" : "     "
        print("\(mark)  \(device.addressString ?? "?")  \(device.nameOrAddress ?? "?")")
    }
    if !paired.contains(where: \.isHandsFreeAudioGateway) {
        print("No paired phone. Pair it from System Settings > Bluetooth first.")
    }
    exit(0)
}

let normalized = target.lowercased().replacingOccurrences(of: ":", with: "-")
guard let device = paired.first(where: {
    $0.addressString?.lowercased().replacingOccurrences(of: ":", with: "-") == normalized
}) else {
    print("No paired device at \(target). Run `HandsFreeProbe list`.")
    exit(1)
}

if let channel = arguments.dropFirst().first.flatMap({ BluetoothRFCOMMChannelID($0) }) {
    IOBluetoothSDPServiceRecord.overrideGatewayChannel(channel)
}

let probe = Probe(device: device)
// IOBluetooth's Core Bluetooth session needs a moment to reach the powered on state;
// a connect sent before that is dropped with "API MISUSE" in the log.
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { probe.start() }

// Commands come from stdin on a background thread; IOBluetooth wants the main thread.
FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    for line in text.split(separator: "\n") {
        let command = line.trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async { probe.run(command) }
    }
}

RunLoop.main.run()

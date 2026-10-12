import Foundation
import IOBluetooth
import os

/// Bluetooth hands-free link to the phone: dials, answers, hangs up, and reports the
/// call state, including the number of an incoming call.
///
/// The Mac acts as a car kit (HFP). macOS still carries the control channel, but no
/// longer the call audio (SCO), which goes over adb instead: see [CallAudioLink].
///
/// The phone must already be paired, from System Settings > Bluetooth. The link holds
/// while Sidebus runs and comes back on its own when the phone returns in range.
@MainActor
public final class HandsFreeLink: NSObject {

    public enum CallState: Equatable, Sendable {
        case idle
        /// An incoming call ringing, with the caller's number when the network gives it.
        case incoming(number: String?)
        /// An outgoing call, before the other party answers.
        case outgoing
        case active
    }

    public private(set) var state: CallState = .idle
    public private(set) var isConnected = false
    /// Name of the paired phone, nil when none is paired.
    public private(set) var phoneName: String?

    /// Called on every change of `state`, `isConnected` or `phoneName`.
    public var onChange: (() -> Void)?

    private var handsFree: IOBluetoothHandsFreeDevice?
    private var callActive = false
    private var callSetup = 0
    private var incomingNumber: String?
    private var reconnect: Task<Void, Never>?
    private let log = Logger(subsystem: "app.sidebus", category: "phone")

    public override init() {
        super.init()
    }

    /// Connects to the first paired phone, and keeps trying while none answers.
    public func start() {
        guard handsFree == nil else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let phone = paired.first(where: \.isHandsFreeAudioGateway) else {
            phoneName = nil
            onChange?()
            scheduleReconnect()
            return
        }
        phoneName = phone.nameOrAddress
        onChange?()
        // A fresh SDP query first: the record macOS cached at pairing time can name a
        // stale RFCOMM channel, as a Xiaomi 15 did (1 instead of 8), and the hands-free
        // connection then fails without a word.
        phone.performSDPQuery(self)
    }

    public func stop() {
        reconnect?.cancel()
        reconnect = nil
        handsFree?.disconnect()
        handsFree = nil
        isConnected = false
        update()
    }

    public func dial(_ number: String) {
        handsFree?.dialNumber(number)
    }

    public func accept() {
        handsFree?.acceptCall()
    }

    /// Hangs up, or declines a call that rings.
    public func end() {
        handsFree?.endCall()
    }

    public func sendTone(_ digit: String) {
        handsFree?.sendDTMF(digit)
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let handsFree = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        self.handsFree = handsFree
        handsFree?.connect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.handsFree = nil
            self.start()
        }
    }

    private func update() {
        let next: CallState
        if callActive {
            next = .active
        } else {
            switch callSetup {
            case 1: next = .incoming(number: incomingNumber)
            case 2, 3: next = .outgoing
            default: next = .idle
            }
        }
        if next == .idle { incomingNumber = nil }
        state = next
        onChange?()
    }
}

extension HandsFreeLink: @preconcurrency IOBluetoothHandsFreeDeviceDelegate {

    public func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        guard status.intValue == 0 else {
            log.error("hands-free connection failed: \(status.intValue)")
            scheduleReconnect()
            return
        }
        log.info("hands-free connected to \(self.phoneName ?? "?", privacy: .public)")
        isConnected = true
        update()
    }

    public func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        log.info("hands-free disconnected: \(status.intValue)")
        isConnected = false
        callActive = false
        callSetup = 0
        update()
        scheduleReconnect()
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive value: NSNumber!) {
        callActive = value.intValue != 0
        update()
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode value: NSNumber!) {
        callSetup = value.intValue
        update()
    }

    public func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        incomingNumber = number
        update()
    }
}

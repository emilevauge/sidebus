import AVFoundation
import AppKit
import Observation
import SidebusCore
import UserNotifications
import os

/// Phone calls through the user's Android phone: Bluetooth for dialing and the call
/// state, adb for the audio and the contacts. One instance for the whole app, since
/// links, notifications and the menu all reach it.
@MainActor
@Observable
final class PhoneModel {
    static let shared = PhoneModel()

    private(set) var callState: HandsFreeLink.CallState = .idle
    private(set) var isBluetoothConnected = false
    private(set) var phoneName: String?
    private(set) var bridgeStatus: PhoneBridgeHost.Status = .noPhone
    private(set) var contacts: [PhoneContact] = []
    /// True while the Sidebus app on the phone waits for the contacts permission.
    private(set) var contactsNeedPermission = false
    private(set) var isMuted = false
    /// When the current call was answered, for its duration.
    private(set) var answeredAt: Date?
    /// Who the current call is with: a contact's name, or the number.
    private(set) var peer: String?
    /// Last problem worth showing, cleared by the next call.
    private(set) var problem: String?

    @ObservationIgnored private let link = HandsFreeLink()
    @ObservationIgnored private var host: PhoneBridgeHost?
    @ObservationIgnored private var audio: CallAudioLink?
    @ObservationIgnored private let notifications = IncomingCallNotifier()
    @ObservationIgnored private let log = Logger(subsystem: "app.sidebus", category: "phone")

    var isInCall: Bool { callState != .idle }

    /// One line on where calls stand, for the menu and the dialer.
    var summary: String {
        guard isBluetoothConnected else {
            return phoneName.map { "\($0) is not connected over Bluetooth" }
                ?? "No phone paired over Bluetooth"
        }
        switch bridgeStatus {
        case .ready: return "Calls go through \(phoneName ?? "the phone")"
        case .noPhone: return "Plug the phone over USB to hear calls on the Mac"
        case .starting: return "Preparing the phone…"
        case let .failed(reason): return "Call audio unavailable: \(reason)"
        }
    }

    func start() {
        link.onChange = { [weak self] in self?.linkChanged() }
        link.start()

        notifications.onAnswer = { [weak self] in self?.accept() }
        notifications.onDecline = { [weak self] in self?.hangUp() }
        notifications.setUp()

        guard let dex = Bundle.module.url(forResource: "callbridge", withExtension: "dex") else {
            bridgeStatus = .failed("callbridge.dex is missing from the app, run android/callbridge/build.sh")
            return
        }
        let host = PhoneBridgeHost(dex: dex)
        self.host = host
        Task {
            await host.start { status in
                Task { @MainActor in PhoneModel.shared.bridgeChanged(status) }
            }
        }
    }

    // MARK: - Actions

    func dial(_ number: String, name: String? = nil) {
        let dialable = ContactBook.dialable(number)
        guard !dialable.isEmpty else { return }
        problem = nil
        peer = name ?? ContactBook.contact(for: dialable, in: contacts)?.name ?? number
        link.dial(dialable)
    }

    func accept() {
        link.accept()
    }

    func hangUp() {
        link.end()
    }

    func toggleMute() {
        isMuted.toggle()
        audio?.setMuted(isMuted)
    }

    func sendTone(_ digit: String) {
        link.sendTone(digit)
    }

    func refreshContacts() {
        guard let host else { return }
        Task {
            do {
                if let list = try await host.contacts() {
                    contacts = list
                    contactsNeedPermission = false
                } else {
                    contactsNeedPermission = true
                }
            } catch {
                log.error("contacts: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - State

    private func linkChanged() {
        let previous = callState
        callState = link.state
        isBluetoothConnected = link.isConnected
        phoneName = link.phoneName

        switch callState {
        case let .incoming(number):
            let name = number.flatMap { ContactBook.contact(for: $0, in: contacts)?.name }
            peer = name ?? number ?? "Unknown number"
            if previous != callState { notifications.show(caller: peer ?? "") }
        case .active:
            if answeredAt == nil { answeredAt = Date() }
            notifications.clear()
        case .outgoing:
            break
        case .idle:
            notifications.clear()
            answeredAt = nil
            isMuted = false
        }
        syncAudio()
    }

    private func bridgeChanged(_ status: PhoneBridgeHost.Status) {
        bridgeStatus = status
        if status == .ready && contacts.isEmpty { refreshContacts() }
        syncAudio()
    }

    /// Audio runs from the moment a call is placed or answered until it ends, and only
    /// while the bridge runs on the phone.
    private func syncAudio() {
        let wanted = (callState == .active || callState == .outgoing) && bridgeStatus == .ready
        if wanted, audio == nil {
            let audio = CallAudioLink(port: PhoneBridgeHost.port)
            self.audio = audio
            Task {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    problem = "Sidebus may not use the microphone: allow it in System Settings > Privacy & Security > Microphone"
                    return
                }
                guard self.audio === audio else { return }
                do {
                    try audio.start()
                    audio.setMuted(isMuted)
                } catch {
                    problem = "Call audio could not start: \(error.localizedDescription)"
                    self.audio = nil
                }
            }
        } else if !wanted, let audio {
            audio.stop()
            self.audio = nil
        }
    }
}

/// The incoming call banner, with Answer and Decline buttons.
@MainActor
private final class IncomingCallNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?

    private static let category = "incoming-call"
    private static let identifier = "incoming-call"

    /// Notifications need an app bundle; `swift run` has none and would crash on them.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let answer = UNNotificationAction(identifier: "answer", title: "Answer", options: [])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [answer, decline], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(caller: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller
        content.categoryIdentifier = Self.category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clear() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "answer": onAnswer?()
            case "decline": onDecline?()
            // A click on the banner itself shows the call.
            default: DialerPanel.shared.show()
            }
        }
    }
}

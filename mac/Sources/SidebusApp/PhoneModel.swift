import AVFoundation
import AppKit
import Observation
import SidebusCore
import UserNotifications
import os

/// Phone calls through the user's Android phone. Bluetooth places and answers them; the
/// phone's call channel carries their sound and the contacts, over USB or Wi-Fi. One
/// instance for the whole app, since links, notifications and the menu all reach it.
@MainActor
@Observable
final class PhoneModel {
    static let shared = PhoneModel()

    private(set) var callState: HandsFreeLink.CallState = .idle
    private(set) var isBluetoothConnected = false
    private(set) var phoneName: String?
    private(set) var channelState: PhoneChannel.State = .searching
    private(set) var contacts: [PhoneContact] = []
    private(set) var isMuted = false
    /// When the current call was answered, for its duration.
    private(set) var answeredAt: Date?
    /// Who the current call is with: a contact's name, or the number.
    private(set) var peer: String?
    /// The Mac devices the current call's sound goes through.
    private(set) var audioRoute: CallAudioLink.Route?
    /// Last problem worth showing, cleared by the next call.
    private(set) var problem: String?

    @ObservationIgnored private let link = HandsFreeLink()
    @ObservationIgnored private var host: PhoneBridgeHost?
    @ObservationIgnored private var channel: PhoneChannel?
    @ObservationIgnored private var audio: CallAudioLink?
    @ObservationIgnored private var uplink: AsyncStream<Data>.Continuation?
    @ObservationIgnored private let notifications = IncomingCallNotifier()
    @ObservationIgnored private let log = Logger(subsystem: "app.sidebus", category: "phone")

    var isInCall: Bool { callState != .idle }

    /// True when calls can carry their sound to the Mac right now.
    var audioReady: Bool {
        if case .ready(_, _, true, _) = channelState { return true }
        return false
    }

    /// True while the Sidebus app on the phone lacks the contacts permission.
    var contactsNeedPermission: Bool {
        switch channelState {
        case .ready(_, _, _, false), .resting(_, _, _, false): return true
        default: return false
        }
    }

    /// One line on where calls stand, for the menu and the dialer.
    var summary: String {
        guard isBluetoothConnected else {
            return phoneName.map { "\($0) is not connected over Bluetooth" }
                ?? "No phone paired over Bluetooth"
        }
        switch channelState {
        case .searching:
            return "Open Sidebus on the phone once, on the same Wi-Fi or over USB"
        case .connecting:
            return "Reaching the phone…"
        case let .waitingForGrant(phone):
            return "Allow this Mac in the notification on \(phone)"
        case let .refused(phone):
            return "\(phone) refused this Mac its calls"
        case let .ready(phone, over, helperRuns, _), let .resting(phone, over, helperRuns, _):
            guard helperRuns else { return "Plug \(phone) in over USB once to hear calls on the Mac" }
            return "Calls go through \(phone), over \(over == .usb ? "USB" : "Wi-Fi")"
        }
    }

    func start() {
        link.onChange = { [weak self] in self?.linkChanged() }
        link.start()

        notifications.onAnswer = { [weak self] in self?.accept() }
        notifications.onDecline = { [weak self] in self?.hangUp() }
        notifications.setUp()

        let channel = PhoneChannel(macName: Host.current().localizedName ?? "Mac", macUUID: Self.macUUID)
        self.channel = channel
        Task {
            await channel.start { event in
                Task { @MainActor in PhoneModel.shared.channelEvent(event) }
            }
        }

        guard let dex = Bundle.module.url(forResource: "callbridge", withExtension: "dex") else {
            problem = "callbridge.dex is missing from the app, run android/callbridge/build.sh"
            return
        }
        let host = PhoneBridgeHost(dex: dex)
        self.host = host
        Task {
            await host.start { plugged in
                Task { await channel.setUSBAvailable(plugged) }
            }
        }
    }

    /// The Mac's identity, shared with the display sessions.
    private static var macUUID: UUID {
        let key = "macUUID"
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
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
        guard let channel else { return }
        Task { await channel.checkSoon() }
    }

    // MARK: - State

    private func linkChanged() {
        let previous = callState
        callState = link.state
        isBluetoothConnected = link.isConnected
        phoneName = link.phoneName

        if let channel {
            let inCall = callState != .idle
            Task { await channel.setInCall(inCall) }
        }

        switch callState {
        case let .incoming(number):
            let name = number.flatMap { ContactBook.contact(for: $0, in: contacts)?.name }
            peer = name ?? number ?? "Unknown number"
            if previous != callState { notifications.showIncoming(caller: peer ?? "") }
        case .active:
            if answeredAt == nil { answeredAt = Date() }
            notifications.clearIncoming()
        case .outgoing:
            break
        case .idle:
            notifications.clearIncoming()
            answeredAt = nil
            isMuted = false
            if previous != .idle { problem = nil }
        }
        syncAudio()
    }

    private func channelEvent(_ event: PhoneChannel.Event) {
        switch event {
        case let .state(state):
            channelState = state
            switch state {
            case let .ready(phone, _, false, _), let .resting(phone, _, false, _):
                notifications.showPlugIn(phone: phone)
            case .ready(_, _, true, _), .resting(_, _, true, _):
                notifications.clearPlugIn()
            default:
                break
            }
        case let .contacts(list):
            contacts = list
        case let .audio(pcm):
            audio?.play(pcm)
        case .audioStopped:
            stopAudio()
            syncAudio()
        }
        syncAudio()
    }

    /// Audio runs from the moment a call is placed or answered until it ends, while the
    /// phone's helper runs.
    private func syncAudio() {
        let wanted = (callState == .active || callState == .outgoing) && audioReady
        if wanted, audio == nil {
            startAudio()
        } else if !wanted, audio != nil {
            stopAudio()
        }
    }

    private func startAudio() {
        guard let channel else { return }
        // One sender for the whole call, so the microphone's pieces keep their order.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(25))
        uplink = continuation
        Task {
            for await pcm in stream { await channel.send(.callAudio(pcm)) }
        }
        let audio = CallAudioLink { pcm in continuation.yield(pcm) }
        self.audio = audio
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = "Sidebus may not use the microphone: allow it in System Settings > Privacy & Security > Microphone"
                return
            }
            guard self.audio === audio else { return }
            do {
                try audio.start()
                audioRoute = audio.route
                audio.setMuted(isMuted)
                await channel.send(.callStart)
            } catch {
                problem = "Call audio could not start: \(error.localizedDescription)"
                stopAudio()
            }
        }
    }

    private func stopAudio() {
        guard let audio else { return }
        audio.stop()
        self.audio = nil
        audioRoute = nil
        uplink?.finish()
        uplink = nil
        if let channel { Task { await channel.send(.callStop) } }
    }
}

/// The incoming call banner, with Answer and Decline buttons.
@MainActor
private final class IncomingCallNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?

    private static let category = "incoming-call"
    private static let identifier = "incoming-call"
    private static let plugInIdentifier = "plug-in"

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

    func showIncoming(caller: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller
        content.categoryIdentifier = Self.category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clearIncoming() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    /// The phone's call helper is not running, since the phone restarted: one USB plug
    /// starts it again, and it then runs until the next restart.
    func showPlugIn(phone: String) {
        guard let center, !plugInShown else { return }
        plugInShown = true
        let content = UNMutableNotificationContent()
        content.title = "Plug \(phone) in over USB"
        content.body = "Once after each restart of the phone, to hear its calls on the Mac. You can unplug it right after."
        center.add(UNNotificationRequest(identifier: Self.plugInIdentifier, content: content, trigger: nil))
    }

    func clearPlugIn() {
        plugInShown = false
        center?.removeDeliveredNotifications(withIdentifiers: [Self.plugInIdentifier])
    }

    private var plugInShown = false

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
            default: AppDelegate.shared.showPanel()
            }
        }
    }
}

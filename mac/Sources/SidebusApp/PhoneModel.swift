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
    /// True when the call goes through the Mac's speakers and microphone: placed or
    /// answered from the Mac, or moved to it. A call placed or answered on the phone
    /// stays there.
    private(set) var callOnMac = false
    /// The link to the phone fell during a call on the Mac: the sound went back to the
    /// phone until it comes back.
    private(set) var linkLost = false
    /// Whether the phone passes on who calls, as its call screen shows it.
    private(set) var callerNamesReadable = false
    /// When the current call was answered, for its duration.
    private(set) var answeredAt: Date?
    /// Who the current call is with: a contact's name, or the number.
    private(set) var peer: String?
    /// The current call's number, when known, for its country.
    private(set) var peerNumber: String?

    /// "🇺🇸 United States" for the current call's number.
    var peerCountry: String? { peerNumber.flatMap { CallingCode.label(of: $0) } }
    /// The phone's identifier among the paired devices, once its call channel told it.
    private(set) var phoneDeviceID: String? = UserDefaults.standard.string(forKey: "phoneDeviceID")
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

    /// True when the last word from the phone is that calls can reach the Mac.
    var callsAvailable: Bool {
        switch channelState {
        case .ready(_, _, true, _), .resting(_, _, true, _): return true
        default: return false
        }
    }

    /// How the phone was last reached for calls.
    var channelTransport: TransportKind? {
        switch channelState {
        case let .ready(_, over, _, _), let .resting(_, over, _, _): return over
        default: return nil
        }
    }

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
            return "Sound stays on the phone: it is not on this Wi-Fi, nor plugged in"
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
        peerNumber = dialable
        callOnMac = true
        link.dial(dialable)
        syncAudio()
    }

    func accept() {
        callOnMac = true
        link.accept()
        syncAudio()
    }

    /// Moves the call under way to the Mac, or back to the phone.
    func moveCall(toMac: Bool) {
        callOnMac = toMac
        syncChannel()
        syncAudio()
    }

    /// The phone's call screen named the caller: shown in place of a bare number, with
    /// what it adds (a spam warning, a business), unless a contact already names it.
    private func callerShown(title: String, text: String) {
        log.info("caller from the phone: \(title, privacy: .private) / \(text, privacy: .private)")
        guard case let .incoming(number) = callState else { return }
        if let number, ContactBook.contact(for: number, in: contacts) != nil { return }
        let digits = ContactBook.dialable(title)
        // A title that is only the number again adds nothing, unless Bluetooth gave none.
        let isNumber = !digits.isEmpty && digits.count * 2 >= title.filter { !$0.isWhitespace }.count
        guard !title.isEmpty, !isNumber || number == nil else { return }
        if isNumber, number == nil { peerNumber = title }
        let generic = ["incoming call", "appel entrant", "appel vocal entrant"]
        let detail = generic.contains(text.lowercased()) ? nil : text.isEmpty ? nil : text
        phoneCaller = detail.map { "\(title) · \($0)" } ?? title
        peer = phoneCaller
        notifications.showIncoming(caller: incomingBody)
    }

    /// The incoming call notification's text: who, then the number and its country.
    private var incomingBody: String {
        let numberLine = [peerNumber.flatMap { $0 == peer ? nil : $0 }, peerCountry].compactMap { $0 }.joined(separator: " · ")
        return [peer, numberLine.isEmpty ? nil : numberLine].compactMap { $0 }.joined(separator: "\n")
    }

    /// Who rings, as the phone's call screen named it, for the ringing call only.
    @ObservationIgnored private var phoneCaller: String?

    private func syncChannel() {
        guard let channel else { return }
        let wanted = callOnMac || {
            if case .incoming = callState { return true }
            return false
        }()
        let holds = callState != .idle && wanted
        Task { await channel.setInCall(holds) }
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

        switch callState {
        case let .incoming(number):
            let name = number.flatMap { ContactBook.contact(for: $0, in: contacts)?.name }
            peer = name ?? phoneCaller ?? number ?? "Unknown number"
            if let number { peerNumber = number }
            if previous != callState {
                notifications.showIncoming(caller: incomingBody)
                AppDelegate.shared.showPanelForCall()
            }
        case .active:
            if answeredAt == nil { answeredAt = Date() }
            notifications.clearIncoming()
        case .outgoing:
            // Placed on the phone itself: it stays there.
            if previous == .idle, !callOnMac {
                peer = "Call on the phone"
            }
        case .idle:
            notifications.clearIncoming()
            answeredAt = nil
            isMuted = false
            callOnMac = false
            linkLost = false
            phoneCaller = nil
            peerNumber = nil
            if previous != .idle {
                problem = nil
                AppDelegate.shared.callEnded()
            }
        }
        syncChannel()
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
            lastAudioAt = .now
            if linkLost { linkLost = false }
            audio?.play(pcm)
        case let .caller(title, text):
            callerShown(title: title, text: text)
        case let .callerNamesReadable(readable):
            callerNamesReadable = readable
        case let .device(uuid):
            phoneDeviceID = uuid.uuidString
            UserDefaults.standard.set(uuid.uuidString, forKey: "phoneDeviceID")
        case .audioStopped:
            if streaming, callOnMac, callState == .active { linkLost = true }
            // The phone ended the sound (the call, or the link, is over): CALL_START again
            // if the call goes on over a new link.
            streaming = false
        }
        syncAudio()
    }

    /// True when the last word from the phone is that its helper runs, live or from the
    /// last check: the call's sound can come to the Mac once the link is up.
    private var helperKnownRunning: Bool {
        switch channelState {
        case .ready(_, _, true, _), .resting(_, _, true, _): return true
        default: return false
        }
    }

    /// For a call on the Mac, the engine starts as soon as Bluetooth announces it, ringing
    /// included, so that
    /// voice processing (a second or so to set up) gets ready while the link to the phone
    /// comes up; the sound flows once both are there, from the moment the call is placed
    /// or answered, until it ends.
    private func syncAudio() {
        // Ringing: warmed up in case the call is answered from the Mac.
        let ringing: Bool = {
            if case .incoming = callState { return true }
            return false
        }()
        let engineWanted = callState != .idle && helperKnownRunning && (callOnMac || ringing)
        if engineWanted, audio == nil {
            startAudio()
        } else if !engineWanted, audio != nil {
            stopAudio()
        }

        let streamWanted = callOnMac && (callState == .active || callState == .outgoing) && audioReady && audioStarted
        if streamWanted, !streaming {
            streaming = true
            lastAudioAt = .now
            watchAudio()
            if let channel { Task { await channel.send(.callStart) } }
        } else if !streamWanted, streaming {
            streaming = false
            if let channel { Task { await channel.send(.callStop) } }
        }
    }

    @ObservationIgnored private var lastAudioAt = ContinuousClock.now
    @ObservationIgnored private var audioWatch: Task<Void, Never>?

    /// While the sound flows, about 50 pieces a second come from the phone: two seconds
    /// without one mean the link fell, long before its own five second deadline.
    private func watchAudio() {
        audioWatch?.cancel()
        audioWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.streaming else { return }
                if ContinuousClock.now - self.lastAudioAt > .seconds(2) {
                    self.log.info("no sound from the phone for 2 s, dropping the link")
                    self.linkLost = true
                    self.streaming = false
                    if let channel = self.channel { await channel.dropLink() }
                    return
                }
            }
        }
    }

    /// The engine runs (`audio.start()` went through).
    @ObservationIgnored private var audioStarted = false
    /// CALL_START sent, CALL_STOP not yet.
    @ObservationIgnored private var streaming = false

    private func startAudio() {
        guard let channel else { return }
        // One sender for the whole call, so the microphone's pieces keep their order. The
        // phone drops them until CALL_START.
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
                audioStarted = true
                syncAudio()
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
        audioStarted = false
        audioRoute = nil
        uplink?.finish()
        uplink = nil
        if streaming {
            streaming = false
            if let channel { Task { await channel.send(.callStop) } }
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

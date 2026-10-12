import AppKit
import SidebusCore
import SwiftUI

/// What is typed in the dialer, kept across openings.
@MainActor
@Observable
final class DialerEntry {
    var text = ""
}

/// The phone part of the panel: a search field to place a call, or the call under way.
struct PhoneCard: View {
    let phone: PhoneModel
    @Bindable var entry: DialerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stacked, not one under the other: during the fade both are there, and in a
            // column the card, then the popover, would grow by both for a moment.
            ZStack(alignment: .top) {
                if phone.isInCall {
                    CallView(phone: phone)
                        .transition(.opacity)
                } else {
                    SearchView(phone: phone, entry: entry)
                        .transition(.opacity)
                }
            }
            if let problem = phone.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // One curve for the card and the popover around it, which PopoverHost resizes
        // with the same timing.
        .animation(Motion.resize, value: phone.isInCall)
        .animation(Motion.resize, value: phone.callOnMac)
        .animation(Motion.resize, value: phone.audioRoute)
        .animation(Motion.resize, value: phone.problem)
    }
}

// MARK: - Placing a call

private struct SearchView: View {
    let phone: PhoneModel
    @Bindable var entry: DialerEntry
    @FocusState private var focused: Bool
    @State private var field: NSView?
    private let suggestions = SuggestionPanel.shared

    /// The typed text, when it reads as a number rather than a name.
    private var typedNumber: String? {
        let digits = ContactBook.dialable(entry.text)
        return digits.count >= 2 && digits.count * 2 >= entry.text.filter { !$0.isWhitespace }.count ? digits : nil
    }

    private var choices: [CallChoice] {
        var list = typedNumber.map { [CallChoice(title: "Call \(entry.text)", detail: "", number: $0, name: nil)] } ?? []
        list += ContactBook.search(entry.text, in: phone.contacts, limit: 8)
            .map { CallChoice(title: $0.name, detail: $0.number, number: $0.number, name: $0.name) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "phone")
                    .foregroundStyle(.secondary)
                TextField("Call a name or a number", text: $entry.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                .onSubmit { call(suggestions.model.selection) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    guard !entry.text.isEmpty else { return .ignored }
                    entry.text = ""
                    return .handled
                }
                    .onChange(of: entry.text) { refreshSuggestions(resetSelection: true) }
                    .onChange(of: phone.contacts) { refreshSuggestions(resetSelection: false) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(AnchorView { field = $0 })

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(phone.callsAvailable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        }
        .onAppear {
            focused = true
            if phone.contacts.isEmpty { phone.refreshContacts() }
            refreshSuggestions(resetSelection: false)
        }
        .onDisappear { suggestions.hide() }
    }

    private var status: String {
        if phone.contactsNeedPermission {
            return "Tap the Sidebus notification on the phone to let the Mac search your contacts"
        }
        return phone.summary
    }

    private func refreshSuggestions(resetSelection: Bool) {
        let model = suggestions.model
        model.choices = choices
        if resetSelection || model.selection >= model.choices.count { model.selection = 0 }
        model.onPick = { index in call(index) }
        suggestions.update(beside: field)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let model = suggestions.model
        guard !model.choices.isEmpty else { return .ignored }
        model.selection = min(max(model.selection + step, 0), model.choices.count - 1)
        return .handled
    }

    private func call(_ index: Int) {
        let list = suggestions.model.choices
        guard list.indices.contains(index) else { return }
        let choice = list[index]
        phone.dial(choice.number, name: choice.name)
        entry.text = ""
        suggestions.hide()
    }
}

// MARK: - During a call

private struct CallView: View {
    let phone: PhoneModel
    @State private var showsKeypad = false

    var body: some View {
        VStack(spacing: 12) {
            Text(phone.peer ?? "").font(.title2).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(state(at: context.date)).foregroundStyle(.secondary).monospacedDigit()
            }
            // Every line is there from the first moment of the call, only its text changes:
            // lines coming and going while the link comes up resized the popover several
            // times in a row.
            VStack(spacing: 2) {
                if phone.callOnMac {
                    Label(phone.audioRoute?.microphone ?? "Microphone", systemImage: "mic")
                    Label(phone.audioRoute?.speaker ?? "Speakers", systemImage: "speaker.wave.2")
                } else {
                    Label("On the phone", systemImage: "iphone")
                    Label("Its earpiece and microphone", systemImage: "ear")
                }
                Text(soundStatus).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showsKeypad {
                Keypad { phone.sendTone($0) }
            }

            HStack(spacing: 20) {
                if case .incoming = phone.callState {
                    RoundButton(symbol: "phone.down.fill", color: .red, title: "Decline") { phone.hangUp() }
                    RoundButton(symbol: "phone.fill", color: .green, title: "Answer") { phone.accept() }
                } else {
                    if phone.callOnMac {
                        RoundButton(
                            symbol: phone.isMuted ? "mic.slash.fill" : "mic.fill",
                            color: phone.isMuted ? .orange : .gray,
                            title: phone.isMuted ? "Unmute" : "Mute"
                        ) { phone.toggleMute() }
                    }
                    RoundButton(symbol: "circle.grid.3x3.fill", color: .gray, title: "Keypad") { showsKeypad.toggle() }
                    RoundButton(symbol: "phone.down.fill", color: .red, title: "Hang up") { phone.hangUp() }
                }
            }
            Button(phone.callOnMac ? "Move to the phone" : "Move to the Mac") {
                phone.moveCall(toMac: !phone.callOnMac)
            }
            .buttonStyle(.link)
            .disabled(phone.callState != .active || (!phone.callOnMac && !phone.callsAvailable))
        }
        .frame(maxWidth: .infinity)
    }

    private var soundStatus: String {
        guard phone.callOnMac else {
            return phone.callsAvailable ? " " : phone.summary
        }
        if let route = phone.audioRoute {
            return route.echoCancellation ? "Echo cancellation on" : "Echo cancellation off: use headphones"
        }
        return phone.callsAvailable ? "Starting the sound…" : phone.summary
    }

    private func state(at date: Date) -> String {
        switch phone.callState {
        case .incoming: return "Incoming call"
        case .outgoing: return "Calling…"
        case .idle: return ""
        case .active:
            let seconds = Int(date.timeIntervalSince(phone.answeredAt ?? date))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let color: Color
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(color, in: .circle)
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct Keypad: View {
    let press: (String) -> Void
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { key in
                        Button(key) { press(key) }
                            .font(.title3.monospaced())
                            .frame(width: 44)
                    }
                }
            }
        }
    }
}

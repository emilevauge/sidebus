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
            if phone.isInCall {
                CallView(phone: phone)
            } else {
                SearchView(phone: phone, entry: entry)
            }
            if let problem = phone.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Placing a call

private struct SearchView: View {
    let phone: PhoneModel
    @Bindable var entry: DialerEntry
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [PhoneContact] {
        ContactBook.search(entry.text, in: phone.contacts, limit: 6)
    }

    /// The typed text, when it reads as a number rather than a name.
    private var typedNumber: String? {
        let digits = ContactBook.dialable(entry.text)
        return digits.count >= 2 && digits.count * 2 >= entry.text.filter { !$0.isWhitespace }.count ? digits : nil
    }

    private var choices: [(title: String, detail: String, number: String, name: String?)] {
        var list = typedNumber.map { [(title: "Call \(entry.text)", detail: "", number: $0, name: String?.none)] } ?? []
        list += matches.map { (title: $0.name, detail: $0.number, number: $0.number, name: Optional($0.name)) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Call a name or a number", text: $entry.text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused)
                .onSubmit(callSelection)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onChange(of: entry.text) { selection = 0 }

            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    selection = index
                    callSelection()
                } label: {
                    HStack {
                        Text(choice.title)
                        Spacer()
                        Text(choice.detail).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(index == selection ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Text(status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            focused = true
            if phone.contacts.isEmpty { phone.refreshContacts() }
        }
    }

    private var status: String {
        if phone.contactsNeedPermission {
            return "Tap the Sidebus notification on the phone to let the Mac search your contacts"
        }
        return phone.summary
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = min(max(selection + step, 0), choices.count - 1)
        return .handled
    }

    private func callSelection() {
        guard choices.indices.contains(selection) else { return }
        let choice = choices[selection]
        phone.dial(choice.number, name: choice.name)
        entry.text = ""
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
            if let route = phone.audioRoute {
                VStack(spacing: 2) {
                    Label(route.microphone, systemImage: "mic")
                    Label(route.speaker, systemImage: "speaker.wave.2")
                    Text(route.echoCancellation ? "Echo cancellation on" : "Echo cancellation off: use headphones")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if phone.isInCall, !phone.audioReady {
                Text("Sound stays on the phone: \(phone.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showsKeypad {
                Keypad { phone.sendTone($0) }
            }

            HStack(spacing: 20) {
                if case .incoming = phone.callState {
                    RoundButton(symbol: "phone.down.fill", color: .red, title: "Decline") { phone.hangUp() }
                    RoundButton(symbol: "phone.fill", color: .green, title: "Answer") { phone.accept() }
                } else {
                    RoundButton(
                        symbol: phone.isMuted ? "mic.slash.fill" : "mic.fill",
                        color: phone.isMuted ? .orange : .gray,
                        title: phone.isMuted ? "Unmute" : "Mute"
                    ) { phone.toggleMute() }
                    RoundButton(symbol: "circle.grid.3x3.fill", color: .gray, title: "Keypad") { showsKeypad.toggle() }
                    RoundButton(symbol: "phone.down.fill", color: .red, title: "Hang up") { phone.hangUp() }
                }
            }
        }
        .frame(maxWidth: .infinity)
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

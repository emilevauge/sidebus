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
        .animation(Motion.resize, value: phone.problem)
    }
}

// MARK: - Placing a call

/// One line the call field suggests: a contact's number, or the typed number itself.
private struct CallChoice: Equatable {
    let title: String
    let detail: String
    let number: String
    let name: String?
}

private struct SearchView: View {
    let phone: PhoneModel
    @Bindable var entry: DialerEntry
    @FocusState private var focused: Bool
    @State private var selection = 0

    /// The typed text, when it reads as a number rather than a name.
    private var typedNumber: String? {
        let digits = ContactBook.dialable(entry.text)
        return digits.count >= 2 && digits.count * 2 >= entry.text.filter { !$0.isWhitespace }.count ? digits : nil
    }

    private var choices: [CallChoice] {
        guard phone.callsAvailable else { return [] }
        var list = typedNumber.map { [CallChoice(title: "Call \(entry.text)", detail: "", number: $0, name: nil)] } ?? []
        list += ContactBook.search(entry.text, in: phone.contacts, limit: 6)
            .map { CallChoice(title: $0.name, detail: $0.number, number: $0.number, name: $0.name) }
        return list
    }

    var body: some View {
        let choices = self.choices
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: phone.callsAvailable ? "phone" : "phone.down")
                    .foregroundStyle(.secondary)
                TextField(phone.callsAvailable ? "Call a name or a number" : "Calls stay on the phone", text: $entry.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .disabled(!phone.callsAvailable)
                    .onSubmit { call(choices, selection) }
                    .onKeyPress(.downArrow) { move(1, in: choices) }
                    .onKeyPress(.upArrow) { move(-1, in: choices) }
                    .onKeyPress(.escape) {
                        guard !entry.text.isEmpty else { return .ignored }
                        entry.text = ""
                        return .handled
                    }
                    .onChange(of: entry.text) { selection = 0 }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Greyed out plainly when calls cannot reach the Mac: flat, dashed, faded.
            .background(
                phone.callsAvailable ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                if !phone.callsAvailable {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .opacity(phone.callsAvailable ? 1 : 0.55)

            // Under the field, in the panel: the popover grows and shrinks around the
            // list, its content held still (see PopoverHost).
            if !choices.isEmpty {
                VStack(spacing: 1) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        SuggestionRow(choice: choice, selected: index == selection) {
                            call(choices, index)
                        }
                    }
                }
                .transition(.opacity)
            }

            // Only when something is wrong: when all is well, the phone's icons in the
            // device list say so.
            if let problem = statusProblem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
            }
        }
        .animation(Motion.resize, value: choices.count)
        .onAppear {
            focused = true
            if phone.contacts.isEmpty { phone.refreshContacts() }
        }
    }

    /// What concerns calling itself; the phone's state shows in its row of the devices.
    private var statusProblem: String? {
        if phone.contactsNeedPermission {
            return "Tap the Sidebus notification on the phone to let the Mac search your contacts"
        }
        return nil
    }

    private func move(_ step: Int, in choices: [CallChoice]) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = min(max(selection + step, 0), choices.count - 1)
        return .handled
    }

    private func call(_ choices: [CallChoice], _ index: Int) {
        guard choices.indices.contains(index) else { return }
        let choice = choices[index]
        phone.dial(choice.number, name: choice.name)
        entry.text = ""
    }
}

private struct SuggestionRow: View {
    let choice: CallChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(choice.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - During a call

private struct CallView: View {
    let phone: PhoneModel
    @State private var showsKeypad = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(phone.peer ?? "").font(.title2).lineLimit(1)
                // Held from the start, empty until the number is known.
                Text(phone.peerCountry ?? " ").font(.subheadline).foregroundStyle(.secondary)
            }
            // Text that changes swaps in place; moves still follow the card's animation.
            .animation(nil, value: phone.peer)
            .animation(nil, value: phone.peerCountry)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(state(at: context.date)).foregroundStyle(.secondary).monospacedDigit()
                    .animation(nil, value: context.date)
            }
            // One line, there from the first moment of the call and empty unless something
            // needs saying, so the card never changes height.
            Text(soundStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .animation(nil, value: soundStatus)

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
                    RoundButton(symbol: "circle.grid.3x3.fill", color: .gray, title: "Keypad") { toggleKeypad() }
                    RoundButton(symbol: "phone.down.fill", color: .red, title: "Hang up") { phone.hangUp() }
                }
            }
            Button(phone.callOnMac ? "Move to the phone" : "Move to the Mac") {
                phone.moveCall(toMac: !phone.callOnMac)
            }
            .buttonStyle(.link)
            .disabled(phone.callState != .active || (!phone.callOnMac && !phone.callsAvailable))

            // Last: the popover grows and uncovers it, nothing above moves.
            if showsKeypad {
                Keypad { phone.sendTone($0) }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        // Development hook: SIDEBUS_KEYPAD_LOOP=1 opens and closes the keypad every two
        // seconds, to watch the animation with no hand on the mouse.
        .task {
            guard ProcessInfo.processInfo.environment["SIDEBUS_KEYPAD_LOOP"] == "1" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                toggleKeypad()
            }
        }
    }

    /// Opening, the popover makes room first, with nothing animating, then the keypad
    /// fades into it: resized during SwiftUI's animation, the popover made SwiftUI move
    /// every view from positions offset by the added height. Closing needs no care.
    private func toggleKeypad() {
        guard !showsKeypad else {
            withAnimation(Motion.resize) { showsKeypad = false }
            return
        }
        AppDelegate.shared.growPanel(by: Keypad.height + 12)
        DispatchQueue.main.async {
            withAnimation(Motion.resize) { showsKeypad = true }
        }
    }

    private var soundStatus: String {
        guard phone.callOnMac else { return "On the phone" }
        guard let route = phone.audioRoute else { return "Starting the sound…" }
        return route.echoCancellation ? " " : "Echo cancellation off: use headphones"
    }

    private func state(at date: Date) -> String {
        if phone.dialing { return "Reaching the phone…" }
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
    /// Fixed, so the popover can make room for it before it shows.
    static let height: CGFloat = 4 * 30 + 3 * 6
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { key in
                        Button(key) { press(key) }
                            .font(.title3.monospaced())
                            .frame(width: 44, height: 30)
                    }
                }
            }
        }
    }
}

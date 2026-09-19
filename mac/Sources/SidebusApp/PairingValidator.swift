import AppKit
import Foundation
import Observation
import SidebusCore
import os

/// Applies the `known_hosts` model: a known fingerprint passes, an unknown one asks the
/// user, and one that changes for a known device is refused.
///
/// Pairing happens in two steps, and this class only covers the first. It gets the Mac
/// user's agreement during the TLS handshake, since that is where the fingerprint appears,
/// but it **records nothing**. Recording waits for the tablet's PAIR_RESULT, so for the
/// other side's agreement: `DeviceSession` then calls `commitPending`. A pairing refused on
/// one side therefore leaves no trace on the other.
///
/// One instance per session: the pending fingerprint belongs to one precise connection,
/// and two tablets can pair at the same time.
@MainActor
@Observable
final class PairingValidator: CertificateValidator {

    /// Fingerprint accepted on the Mac side, waiting for the tablet's confirmation.
    private(set) var pendingFingerprint: Data?
    private(set) var lastRefusal: String?

    /// Fingerprint of the current connection, already paired or not.
    private(set) var acceptedFingerprint: Data?

    /// True while a dialog waits for a human answer. The connection deadline pauses as long
    /// as this holds: the time spent reading a code says nothing about whether the tablet
    /// is reachable.
    private(set) var isAskingUser = false

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "pairing")

    nonisolated init() {}

    /// True while the tablet still has to confirm, through PAIR_REQUEST then PAIR_RESULT.
    var awaitsRemoteConfirmation: Bool { pendingFingerprint != nil }

    /// Code to show at both ends, derived from the fingerprint.
    var pendingCode: UInt32? {
        pendingFingerprint.map(PairingCode.value(for:))
    }

    /// Storage access happens off the main actor: a system dialog opened by the keychain
    /// would otherwise freeze the whole app in the middle of the handshake.
    private func storeAccess<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    func shouldAccept(fingerprint: Data, expectedDeviceID: String?) async -> Bool {
        if let expectedDeviceID,
            let known = await storeAccess({ PairingStore.shared.fingerprint(forDeviceID: expectedDeviceID) }) {
            guard known == fingerprint else {
                lastRefusal = """
                    The fingerprint of "\(expectedDeviceID)" has changed. Connection refused.
                    """
                log.error("different fingerprint for \(expectedDeviceID, privacy: .public), refused")
                isAskingUser = true
                await showMismatch(deviceID: expectedDeviceID)
                isAskingUser = false
                return false
            }
            acceptedFingerprint = fingerprint
            return true
        }

        // On USB the identifier only arrives after the handshake, so the device is known by
        // its fingerprint alone.
        if expectedDeviceID == nil, await storeAccess({ PairingStore.shared.isKnown(fingerprint) }) {
            acceptedFingerprint = fingerprint
            return true
        }

        isAskingUser = true
        let accepted = await confirmPairing(code: PairingCode.code(for: fingerprint))
        isAskingUser = false
        guard accepted else {
            lastRefusal = "pairing refused on the Mac"
            return false
        }

        // Nothing is written here: the tablet has to confirm in turn.
        pendingFingerprint = fingerprint
        acceptedFingerprint = fingerprint
        lastRefusal = nil
        return true
    }

    /// Records the fingerprint, once both sides agree.
    func commitPending(deviceID: UUID) throws {
        guard let fingerprint = pendingFingerprint else { return }
        try PairingStore.shared.save(fingerprint, forDeviceID: deviceID.uuidString)
        pendingFingerprint = nil
        log.info("device paired under \(deviceID.uuidString, privacy: .public)")
    }

    /// Drops the pairing under way: the tablet refused, or never answered.
    func discardPending(reason: String) {
        guard pendingFingerprint != nil else { return }
        pendingFingerprint = nil
        lastRefusal = reason
        log.info("pairing dropped: \(reason, privacy: .public)")
    }

    private func confirmPairing(code: String) async -> Bool {
        // Development hook, to exercise the chain without a human.
        if ProcessInfo.processInfo.environment["SIDEBUS_AUTO_PAIR"] == "1" {
            log.info("automatic pairing (SIDEBUS_AUTO_PAIR), code \(code, privacy: .public)")
            return true
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Pair with this tablet?"
        alert.informativeText = """
            Code shown on the tablet: \(code)

            Check that both codes match before confirming. If they differ, somebody else is \
            impersonating your tablet.

            The tablet will then ask for its own confirmation.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Refuse")

        // Same deadline as the one bounding the connection's pause. Without it the alert
        // outlives the connection it belongs to, and clicking "Pair" an hour later answers
        // a socket that closed long ago.
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: Sidebus.humanAnswerDeadline)
            guard !Task.isCancelled else { return }
            self.log.info("pairing prompt left unanswered, closing it")
            NSApp.abortModal()
        }
        defer { deadline.cancel() }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showMismatch(deviceID: String) async {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "This tablet no longer presents the same certificate"
        alert.informativeText = """
            Device "\(deviceID)" was paired with a different certificate. The connection is \
            refused.

            Either the app was reinstalled on the tablet, or somebody is impersonating it. To \
            pair again on purpose, unpair the device in the Sidebus settings.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
}

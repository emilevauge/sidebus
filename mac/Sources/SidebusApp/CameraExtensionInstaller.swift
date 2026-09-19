import Foundation
import Observation
import SystemExtensions
import os

/// Installs and removes the Core Media I/O extension.
///
/// The extension is what turns the phone camera into a camera every application can open,
/// rather than a window that only screen sharing can pass along. It lives inside the app
/// bundle and the system copies it out on request.
///
/// It only works on a Mac whose protections have been lowered, because the request needs
/// `com.apple.developer.system-extension.install`, an entitlement Apple grants through a
/// provisioning profile and refuses to a personal development team. See
/// `docs/camera-extension.md`.
@MainActor
@Observable
final class CameraExtensionInstaller: NSObject {

    static let bundleIdentifier = "app.sidebus.camera"

    enum State: Equatable {
        case unknown
        case absent
        case installing
        case installed
        case needsApproval
        case failed(String)
    }

    private(set) var state: State = .unknown

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "extension")

    /// True when this build carries the extension at all. A build without it must not offer
    /// a button that can only fail.
    var isAvailable: Bool {
        Bundle.main.builtInPlugInsURL != nil
            && FileManager.default.fileExists(atPath: embeddedPath)
    }

    private var embeddedPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(Self.bundleIdentifier).systemextension")
            .path
    }

    func install() {
        state = .installing
        log.info("activation requested for \(Self.bundleIdentifier, privacy: .public)")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        state = .installing
        log.info("deactivation requested")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    var summary: String {
        switch state {
        case .unknown: return "not checked"
        case .absent: return "not installed"
        case .installing: return "working…"
        case .installed: return "installed, the camera is available to every application"
        case .needsApproval: return "waiting for your approval in System Settings"
        case let .failed(reason): return reason
        }
    }
}

extension CameraExtensionInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the one in this bundle, including a downgrade: during development the
        // version number rarely moves while the code does.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .needsApproval
            self.log.info("approval needed in System Settings")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.state = .installed
                self.log.info("extension installed")
            case .willCompleteAfterReboot:
                self.state = .failed("installed, but only active after a restart")
            @unknown default:
                self.state = .failed("unexpected result")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .failed("\(error.localizedDescription)")
            self.log.error("request failed: \(String(describing: error), privacy: .public)")
        }
    }
}

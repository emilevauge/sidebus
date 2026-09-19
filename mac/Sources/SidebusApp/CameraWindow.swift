import AppKit
import CoreVideo
import SidebusCore
import SwiftUI

/// Shows the camera stream coming back from a tablet.
///
/// A window for now, not a virtual webcam. Publishing a real camera device to every
/// application means a Core Media I/O system extension, which needs an entitlement only an
/// Apple developer team can grant. Everything below that line, capture, protocol, decoding,
/// is the same work either way, so it comes first.
///
/// Until then the window is shareable in a meeting application, which is not a webcam but
/// does put the picture through.
struct CameraWindow: View {
    let devices: DeviceManager

    /// First session receiving a camera. One at a time is enough while this is a preview.
    private var session: DeviceSession? {
        devices.sessions.first { $0.activeCamera != nil }
    }

    var body: some View {
        ZStack {
            Color.black

            if let session, let frame = session.cameraFrame {
                CameraSurface(frame: frame)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "web.camera")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .navigationTitle(title)
    }

    private var placeholder: String {
        guard let session = devices.sessions.first(where: { !$0.cameras.isEmpty }) else {
            return "No camera offered by any connected tablet"
        }
        return "Pick a camera in the Sidebus menu, under \(session.deviceName ?? "the tablet")"
    }

    private var title: String {
        guard let session, let camera = session.activeCamera else { return "Camera" }
        if let description = session.cameraDescription {
            return "\(camera.label), \(description)"
        }
        return camera.label
    }
}

/// Draws a decoded frame without copying it.
///
/// The buffer is backed by an `IOSurface`, which a `CALayer` can take as its contents
/// directly. Going through `CIImage` and `NSImage` would mean a conversion per frame on the
/// CPU, for a picture the GPU already holds.
private struct CameraSurface: NSViewRepresentable {
    let frame: CapturedFrame

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.show(frame)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.show(frame)
    }
}

final class SurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Letterbox rather than crop: a webcam picture has an aspect ratio of its own and
        // filling the window would cut a face in half.
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ frame: CapturedFrame) {
        guard let surface = CVPixelBufferGetIOSurface(frame.imageBuffer)?.takeUnretainedValue()
        else { return }
        layer?.contents = surface
    }
}

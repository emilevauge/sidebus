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
                CameraSurface(frame: frame, rotation: session.cameraRotation)
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
        guard let entry = devices.entries.first(where: { !$0.cameras.isEmpty }) else {
            return "No camera offered by any paired tablet"
        }
        return "Pick a camera in the Sidebus menu, under \(entry.name)"
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
    let rotation: Int

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.show(frame, rotation: rotation)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.show(frame, rotation: rotation)
    }
}

final class SurfaceView: NSView {
    /// The picture sits in its own layer: the rotation is a transform on that layer, and the
    /// letterboxing is computed on the view around it. A transform on the view's own layer
    /// would turn the black background with it.
    private let imageLayer = CALayer()

    /// Quarter turns clockwise, as CAMERA_CONFIG gives them.
    private var rotation = 0
    private var pixelSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    func show(_ frame: CapturedFrame, rotation: Int) {
        guard let surface = CVPixelBufferGetIOSurface(frame.imageBuffer)?.takeUnretainedValue()
        else { return }

        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.imageBuffer),
            height: CVPixelBufferGetHeight(frame.imageBuffer)
        )
        if size != pixelSize || rotation != self.rotation {
            pixelSize = size
            self.rotation = rotation
            needsLayout = true
        }

        // No implicit animation: at 30 frames a second the crossfade Core Animation adds by
        // default blurs every frame into the next.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }

        // The picture is still in sensor orientation: a quarter or three quarter turn swaps
        // what the window has to make room for.
        let quarterTurned = rotation % 2 != 0
        let shown = quarterTurned
            ? CGSize(width: pixelSize.height, height: pixelSize.width)
            : pixelSize
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: pixelSize.width * scale,
            height: pixelSize.height * scale
        )
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Core Animation turns counter clockwise for a positive angle, the rotation is
        // clockwise: hence the minus sign.
        imageLayer.transform = CATransform3DMakeRotation(
            -CGFloat(rotation) * .pi / 2,
            0,
            0,
            1
        )
        CATransaction.commit()
    }
}

import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import SidebusCore

/// Temporary measurement: CPU cost of the encoding path alone, ScreenCaptureKit excluded.
/// Lancer avec `swift test -c release --filter EncoderBenchmark`.
final class EncoderBenchmark: XCTestCase {

    func testCpuCostOfTheEncodingPath() async throws {
        // Ne tourne pas dans la suite normale : 15 s de mesure.
        // Lancer avec `SIDEBUS_BENCH=1 swift test -c release --filter EncoderBenchmark`.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SIDEBUS_BENCH"] == "1",
            "benchmark disabled, set SIDEBUS_BENCH=1"
        )
        try await mesure(width: 2880, height: 1800)
        try await mesure(width: 2560, height: 1600)
        try await mesure(width: 1920, height: 1200)
    }

    private func mesure(width: Int, height: Int) async throws {
        let fps = 60
        let frameCount = 300

        let encoder = try VideoEncoder(
            configuration: VideoEncoderConfiguration(width: width, height: height, fps: fps)
        )

        let collector = Task { () -> (frames: Int, bytes: Int) in
            var frames = 0
            var bytes = 0
            for await frame in encoder.frames {
                frames += 1
                bytes += frame.data.count
            }
            return (frames, bytes)
        }

        // A pattern shifted from frame to frame: realistic residuals, like a window being
        // dragged. Generated outside the measurement window.
        let buffers = try (0..<16).map { try makePixelBuffer(width: width, height: height, offset: $0 * 7) }

        let startWall = Date()
        let startCpu = cpuSeconds()
        let interval = 1.0 / Double(fps)

        for index in 0..<frameCount {
            let deadline = startWall.addingTimeInterval(Double(index) * interval)
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            try await encoder.encode(
                CapturedFrame(
                    imageBuffer: buffers[index % buffers.count],
                    presentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
                )
            )
        }

        await encoder.finish()
        let wall = -startWall.timeIntervalSinceNow
        let cpu = cpuSeconds() - startCpu
        let result = await collector.value

        print(
            String(
                format: "benchmark %dx%d @%d fps: %d frames encoded, %.1f MB, %.2f s wall, %.2f s CPU, %.1f %% CPU",
                width, height, fps, result.frames,
                Double(result.bytes) / 1_000_000, wall, cpu, cpu / wall * 100
            )
        )
        XCTAssertEqual(result.frames, frameCount)
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func makePixelBuffer(width: Int, height: Int, offset: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        _ = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &buffer
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        // Y plane: a shifted fine checkerboard plus noise, to give the encoder some work.
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var seed = UInt32(truncatingIfNeeded: offset &+ 1)
            for row in 0..<rows {
                for column in 0..<width {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let checker = ((column &+ offset) / 16 &+ row / 16) % 2 == 0 ? 200 : 40
                    pixels[row * stride + column] = UInt8(truncatingIfNeeded: checker &+ Int(seed >> 28))
                }
            }
        }
        // Plan CbCr : gris neutre.
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            memset(base, 128, bytes)
        }
        return pixelBuffer
    }
}

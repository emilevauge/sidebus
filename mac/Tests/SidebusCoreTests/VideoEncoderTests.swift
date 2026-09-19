import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import SidebusCore

final class VideoEncoderTests: XCTestCase {

    func testEncodingProducesAnnexBWithParameterSets() async throws {
        let width = 640
        let height = 480
        let fps = 30

        let encoder = try VideoEncoder(
            configuration: VideoEncoderConfiguration(
                width: width,
                height: height,
                fps: fps,
                bitrate: 2_000_000
            )
        )

        let collector = Task { () -> [EncodedFrame] in
            var collected: [EncodedFrame] = []
            for await frame in encoder.frames {
                collected.append(frame)
            }
            return collected
        }

        for index in 0..<10 {
            let buffer = try makePixelBuffer(width: width, height: height, luma: UInt8(index * 20))
            try await encoder.encode(
                CapturedFrame(
                    imageBuffer: buffer,
                    presentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
                )
            )
        }

        await encoder.finish()
        let frames = await collector.value

        XCTAssertFalse(frames.isEmpty)

        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(first.isKeyframe, "the first frame must be a keyframe")
        XCTAssertEqual(first.data.prefix(4), AnnexB.startCode)

        let parameterSets = try XCTUnwrap(first.parameterSets, "SPS/PPS expected on the first frame")
        XCTAssertEqual(parameterSets.prefix(4), AnnexB.startCode)
        // SPS then PPS, so at least two start codes.
        XCTAssertGreaterThanOrEqual(occurrences(of: AnnexB.startCode, in: parameterSets), 2)

        // Later frames do not re-emit the parameter sets.
        XCTAssertTrue(frames.dropFirst().allSatisfy { $0.parameterSets == nil })
    }

    // MARK: - Utilitaires

    private func makePixelBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            // The hardware encoder demands a buffer backed by an IOSurface.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &buffer
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertEqual(status, kCVReturnSuccess)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * height
            memset(base, Int32(luma), bytes)
        }
        return pixelBuffer
    }

    private func occurrences(of pattern: Data, in data: Data) -> Int {
        var count = 0
        var index = data.startIndex
        while let range = data[index...].range(of: pattern) {
            count += 1
            index = range.upperBound
        }
        return count
    }
}

final class EncoderTerminationTests: XCTestCase {

    /// When capture stops, the encoder must close its stream: that is what tells the
    /// consumer. Without it, the consumer waits for frames that never come and the tablet
    /// stays frozen on its last picture.
    func testTheStreamEndsWhenTheEncoderStops() async throws {
        let encoder = try VideoEncoder(
            configuration: VideoEncoderConfiguration(width: 320, height: 240, fps: 30)
        )

        let terminated = Task { () -> Bool in
            for await _ in encoder.frames {}
            return true
        }

        await encoder.finish()

        let completed = try await withTimeout(.seconds(3)) { await terminated.value }
        XCTAssertTrue(completed, "the encoded stream did not end")
    }
}

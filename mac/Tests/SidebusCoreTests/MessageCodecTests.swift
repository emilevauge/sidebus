import Foundation
import XCTest

@testable import SidebusCore

final class MessageCodecTests: XCTestCase {

    /// `protocol/testvectors/`, located relative to this source file.
    private static let vectorsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SidebusCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("protocol/testvectors")

    private func vector(_ name: String) throws -> Data {
        try Data(contentsOf: Self.vectorsDirectory.appendingPathComponent(name))
    }

    /// Decodes the vector, compares with the expected message, re-encodes and compares bytes.
    private func check(_ name: String, _ expected: Message) throws {
        let bytes = try vector(name)

        var decoder = MessageDecoder()
        decoder.append(bytes)
        let decoded = try XCTUnwrap(try decoder.next(), "\(name): nothing decoded")
        XCTAssertEqual(decoded, expected, "\(name): fields differ")
        XCTAssertNil(try decoder.next(), "\(name) : octets en trop")

        XCTAssertEqual(MessageCodec.encode(expected), bytes, "\(name): re-encoding differs")
    }

    // MARK: - Shared vectors

    func testHello() throws {
        try check(
            "hello.bin",
            .hello(
                version: 1,
                name: "MacBook d'Émile",
                uuid: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
            )
        )
    }

    func testDeviceInfo() throws {
        try check(
            "device_info.bin",
            .deviceInfo(
                width: 2560,
                height: 1600,
                density: 320,
                codecs: 0x03,
                name: "Galaxy Tab S9",
                uuid: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!
            )
        )
    }

    func testDisplayConfig() throws {
        try check("display_config.bin", .displayConfig(width: 2560, height: 1600, fps: 60, codec: .h264))
    }

    func testVideoConfig() throws {
        let parameterSets = Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A])
            + Data([0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0xB0])
        try check("video_config.bin", .videoConfig(parameterSets: parameterSets))
    }

    func testVideoFrameKeyframe() throws {
        try check(
            "video_frame_key.bin",
            .videoFrame(
                timestamp: 1_234_567_890,
                isKeyframe: true,
                data: Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
            )
        )
    }

    func testVideoFrameDelta() throws {
        try check(
            "video_frame_delta.bin",
            .videoFrame(
                timestamp: 1_234_584_557,
                isKeyframe: false,
                data: Data([0, 0, 0, 1, 0x41, 0x9A, 0x22])
            )
        )
    }

    func testInputEvent() throws {
        try check(
            "input_event.bin",
            .inputEvent(kind: .move, x: 0.5, y: 0.25, button: .left, timestamp: 42)
        )
    }

    func testPingPong() throws {
        try check("ping.bin", .ping(timestamp: 0x0102_0304_0506_0708))
        try check("pong.bin", .pong(timestamp: 0x0102_0304_0506_0708))
    }

    func testKeyframeRequest() throws {
        try check("keyframe_req.bin", .keyframeRequest)
    }

    func testStats() throws {
        try check("stats.bin", .stats(received: 120, dropped: 3, windowMilliseconds: 2000))
    }

    func testBye() throws {
        try check("bye.bin", .bye(reason: .transportSwitch))
    }

    func testPairRequest() throws {
        try check("pair_request.bin", .pairRequest(code: 428_913))
    }

    func testPairResult() throws {
        try check("pair_result.bin", .pairResult(accepted: true))
    }

    /// The protocol reserves 1 for acceptance: everything else is a refusal, including a
    /// code this version does not know yet.
    func testPairResultRefusesAnythingButOne() throws {
        let refus = try MessageCodec.decodePayload(
            type: 0x0D,
            flags: 0,
            payload: Data([0x07])
        )
        XCTAssertEqual(refus, .pairResult(accepted: false))
    }

    func testCameraList() throws {
        try check(
            "camera_list.bin",
            .cameraList([
                CameraDescription(id: 0, facing: .back, label: "Back camera"),
                CameraDescription(id: 1, facing: .front, label: "Front camera"),
            ])
        )
    }

    func testCameraStart() throws {
        try check(
            "camera_start.bin",
            .cameraStart(id: 1, width: 1280, height: 720, fps: 30, codec: .h264)
        )
    }

    func testCameraConfig() throws {
        try check(
            "camera_config.bin",
            .cameraConfig(
                width: 1280,
                height: 720,
                codec: .h264,
                rotation: 1,
                parameterSets: Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0, 0, 0, 1, 0x68, 0xCE])
            )
        )
    }

    func testCameraFrame() throws {
        try check(
            "camera_frame.bin",
            .cameraFrame(
                timestamp: 987_654_321,
                isKeyframe: true,
                data: Data([0, 0, 0, 1, 0x65, 0x11, 0x22])
            )
        )
    }

    func testCameraStop() throws {
        try check("camera_stop.bin", .cameraStop)
    }

    func testVideoStop() throws {
        try check("video_stop.bin", .videoStop)
    }

    func testUnknownTypeIsSkippable() throws {
        try check(
            "unknown_type.bin",
            .unknown(type: 0x7F, flags: 0, payload: Data("abc".utf8))
        )
    }

    func testTwoMessagesInOnePacket() throws {
        var decoder = MessageDecoder()
        decoder.append(try vector("stream_two_messages.bin"))
        XCTAssertEqual(try decoder.next(), .ping(timestamp: 0x0102_0304_0506_0708))
        XCTAssertEqual(try decoder.next(), .keyframeRequest)
        XCTAssertNil(try decoder.next())
    }

    // MARK: - Streaming decoder behaviour

    func testMessageDeliveredByteByByte() throws {
        let bytes = try vector("hello.bin")
        var decoder = MessageDecoder()

        for byte in bytes.dropLast() {
            decoder.append(Data([byte]))
            XCTAssertNil(try decoder.next(), "message yielded before it was complete")
        }

        decoder.append(Data([bytes.last!]))
        XCTAssertNotNil(try decoder.next())
    }

    func testInvalidMagicIsFatal() {
        var decoder = MessageDecoder()
        decoder.append(Data([0x00, 0x07, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .badMagic(0x00))
        }
    }

    func testPayloadTooLarge() {
        var decoder = MessageDecoder()
        // length = 16 Mio, au dessus de la borne de 8 Mio.
        decoder.append(Data([0x5B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(16 * 1024 * 1024))
        }
    }

    func testPayloadTruncatedAgainstItsHeader() {
        // PING announced with an 8 byte payload, but only 4 supplied.
        var decoder = MessageDecoder()
        decoder.append(Data([0x5B, 0x07, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .truncatedPayload(.ping))
        }
    }

    func testOutOfRangeCoordinatesAreClamped() throws {
        let message = Message.inputEvent(kind: .down, x: 1.5, y: -0.2, button: .left, timestamp: 7)
        var decoder = MessageDecoder()
        decoder.append(MessageCodec.encode(message))
        let decoded = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(decoded, .inputEvent(kind: .down, x: 1, y: 0, button: .left, timestamp: 7))
    }

    func testOverlongNameIsTruncated() throws {
        let long = String(repeating: "é", count: 200)  // 400 bytes in UTF-8
        let encoded = MessageCodec.encode(.hello(version: 1, name: long, uuid: UUID()))
        var decoder = MessageDecoder()
        decoder.append(encoded)
        let decoded = try XCTUnwrap(try decoder.next())
        guard case let .hello(_, name, _) = decoded else { return XCTFail("HELLO attendu") }
        XCTAssertLessThanOrEqual(name.utf8.count, MessageCodec.maxStringLength)
        XCTAssertTrue(long.hasPrefix(name))
    }
}

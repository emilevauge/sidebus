import Foundation
import XCTest

@testable import SidebusCore

final class MessageCodecTests: XCTestCase {

    /// `protocol/testvectors/`, situé par rapport à ce fichier source.
    private static let vectorsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SidebusCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()  // racine du dépôt
        .appendingPathComponent("protocol/testvectors")

    private func vector(_ name: String) throws -> Data {
        try Data(contentsOf: Self.vectorsDirectory.appendingPathComponent(name))
    }

    /// Décode le vecteur, compare au message attendu, réencode et compare les octets.
    private func check(_ name: String, _ expected: Message) throws {
        let bytes = try vector(name)

        var decoder = MessageDecoder()
        decoder.append(bytes)
        let decoded = try XCTUnwrap(try decoder.next(), "\(name) : rien décodé")
        XCTAssertEqual(decoded, expected, "\(name) : champs différents")
        XCTAssertNil(try decoder.next(), "\(name) : octets en trop")

        XCTAssertEqual(MessageCodec.encode(expected), bytes, "\(name) : réencodage différent")
    }

    // MARK: - Vecteurs partagés

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

    func testTypeInconnuIgnorable() throws {
        try check(
            "unknown_type.bin",
            .unknown(type: 0x7F, flags: 0, payload: Data("abc".utf8))
        )
    }

    func testDeuxMessagesDansLeMemePaquet() throws {
        var decoder = MessageDecoder()
        decoder.append(try vector("stream_two_messages.bin"))
        XCTAssertEqual(try decoder.next(), .ping(timestamp: 0x0102_0304_0506_0708))
        XCTAssertEqual(try decoder.next(), .keyframeRequest)
        XCTAssertNil(try decoder.next())
    }

    // MARK: - Comportement du décodeur en flux

    func testMessageLivreOctetParOctet() throws {
        let bytes = try vector("hello.bin")
        var decoder = MessageDecoder()

        for byte in bytes.dropLast() {
            decoder.append(Data([byte]))
            XCTAssertNil(try decoder.next(), "message rendu avant d'être complet")
        }

        decoder.append(Data([bytes.last!]))
        XCTAssertNotNil(try decoder.next())
    }

    func testMagicInvalideEstFatal() {
        var decoder = MessageDecoder()
        decoder.append(Data([0x00, 0x07, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .badMagic(0x00))
        }
    }

    func testPayloadTropGrand() {
        var decoder = MessageDecoder()
        // length = 16 Mio, au dessus de la borne de 8 Mio.
        decoder.append(Data([0x5B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(16 * 1024 * 1024))
        }
    }

    func testPayloadTronqueDansLEntete() {
        // PING annoncé avec 8 octets de payload, mais 4 seulement fournis.
        var decoder = MessageDecoder()
        decoder.append(Data([0x5B, 0x07, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? ProtocolError, .truncatedPayload(.ping))
        }
    }

    func testCoordonneesHorsBornesRamenees() throws {
        let message = Message.inputEvent(kind: .down, x: 1.5, y: -0.2, button: .left, timestamp: 7)
        var decoder = MessageDecoder()
        decoder.append(MessageCodec.encode(message))
        let decoded = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(decoded, .inputEvent(kind: .down, x: 1, y: 0, button: .left, timestamp: 7))
    }

    func testNomTropLongTronque() throws {
        let long = String(repeating: "é", count: 200)  // 400 octets en UTF-8
        let encoded = MessageCodec.encode(.hello(version: 1, name: long, uuid: UUID()))
        var decoder = MessageDecoder()
        decoder.append(encoded)
        let decoded = try XCTUnwrap(try decoder.next())
        guard case let .hello(_, name, _) = decoded else { return XCTFail("HELLO attendu") }
        XCTAssertLessThanOrEqual(name.utf8.count, MessageCodec.maxStringLength)
        XCTAssertTrue(long.hasPrefix(name))
    }
}

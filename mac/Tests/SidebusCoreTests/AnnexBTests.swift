import Foundation
import XCTest

@testable import SidebusCore

final class AnnexBTests: XCTestCase {

    func testConvertsTwoNalUnits() throws {
        var avcc = Data()
        avcc.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        avcc.append(contentsOf: [0x65, 0x88, 0x84])
        avcc.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        avcc.append(contentsOf: [0x41, 0x9A])

        let annexB = try AnnexB.fromLengthPrefixed(avcc, nalLengthSize: 4)

        XCTAssertEqual(
            annexB,
            Data([
                0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
                0x00, 0x00, 0x00, 0x01, 0x41, 0x9A,
            ])
        )
    }

    func testConvertsATwoBytePrefix() throws {
        let avcc = Data([0x00, 0x02, 0x41, 0x9A])
        let annexB = try AnnexB.fromLengthPrefixed(avcc, nalLengthSize: 2)
        XCTAssertEqual(annexB, Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A]))
    }

    func testEmptyBuffer() throws {
        XCTAssertEqual(try AnnexB.fromLengthPrefixed(Data(), nalLengthSize: 4), Data())
    }

    func testInvalidPrefix() {
        XCTAssertThrowsError(try AnnexB.fromLengthPrefixed(Data([0x01]), nalLengthSize: 5)) { error in
            guard case AnnexB.Error.invalidLengthSize(5) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTruncatedStream() {
        // Annonce 4 octets de NAL, n'en fournit que 2.
        let avcc = Data([0x00, 0x00, 0x00, 0x04, 0x41, 0x9A])
        XCTAssertThrowsError(try AnnexB.fromLengthPrefixed(avcc, nalLengthSize: 4)) { error in
            guard case AnnexB.Error.truncated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTruncatedHeader() {
        XCTAssertThrowsError(try AnnexB.fromLengthPrefixed(Data([0x00, 0x00]), nalLengthSize: 4)) { error in
            guard case AnnexB.Error.truncated = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

final class AnnexBInPlaceTests: XCTestCase {

    private let avcc = Data([0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84])
        + Data([0x00, 0x00, 0x00, 0x02, 0x41, 0x9A])

    func testSameResultAsTheAllocatingVersion() throws {
        var inPlace = avcc
        try AnnexB.convertInPlace(&inPlace, nalLengthSize: 4)
        XCTAssertEqual(inPlace, try AnnexB.fromLengthPrefixed(avcc, nalLengthSize: 4))
    }

    func testSizeUnchanged() throws {
        var data = avcc
        try AnnexB.convertInPlace(&data, nalLengthSize: 4)
        XCTAssertEqual(data.count, avcc.count, "la conversion sur place ne doit rien ajouter")
        XCTAssertEqual(data.prefix(4), AnnexB.startCode)
    }

    func testEmptyBuffer() throws {
        var data = Data()
        try AnnexB.convertInPlace(&data, nalLengthSize: 4)
        XCTAssertTrue(data.isEmpty)
    }

    func testTruncatedStreamIsDetected() {
        var data = Data([0x00, 0x00, 0x00, 0x04, 0x41, 0x9A])
        XCTAssertThrowsError(try AnnexB.convertInPlace(&data, nalLengthSize: 4))
    }

    func testTwoBytePrefixFallsBackToTheOtherPath() throws {
        var data = Data([0x00, 0x02, 0x41, 0x9A])
        try AnnexB.convertInPlace(&data, nalLengthSize: 2)
        XCTAssertEqual(data, Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A]))
    }

}

/// The receiving direction: what `CameraDecoder` needs to hand VideoToolbox.
final class AnnexBReceiveTests: XCTestCase {

    func testSplitYieldsOneEntryPerNalUnit() {
        let data = Data([
            0, 0, 0, 1, 0x67, 0x42, 0x00,
            0, 0, 0, 1, 0x68, 0xCE,
        ])
        let units = AnnexB.split(data)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0], Data([0x67, 0x42, 0x00]))
        XCTAssertEqual(units[1], Data([0x68, 0xCE]))
    }

    /// Three byte start codes turn up in the wild, `MediaCodec` emits them among the four
    /// byte ones.
    func testSplitAcceptsThreeByteStartCodes() {
        let data = Data([0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68])
        XCTAssertEqual(AnnexB.split(data), [Data([0x67, 0x42]), Data([0x68])])
    }

    func testSplitOfEmptyIsEmpty() {
        XCTAssertTrue(AnnexB.split(Data()).isEmpty)
    }

    func testConvertToLengthPrefixedRewritesInPlace() {
        var data = Data([
            0, 0, 0, 1, 0x65, 0x11, 0x22,
            0, 0, 0, 1, 0x41, 0x33,
        ])
        let before = data.count
        AnnexB.convertToLengthPrefixed(&data)

        XCTAssertEqual(data.count, before, "the conversion must not reallocate")
        XCTAssertEqual(Array(data.prefix(4)), [0, 0, 0, 3])
        XCTAssertEqual(Array(data[7..<11]), [0, 0, 0, 2])
    }

    /// The two conversions are each other's inverse. That is what lets a frame travel out
    /// as Annex B and come back into VideoToolbox as AVCC with no copy either way.
    func testRoundTrip() throws {
        let original = Data([
            0, 0, 0, 1, 0x65, 0x11, 0x22, 0x33,
            0, 0, 0, 1, 0x41, 0x44,
        ])
        var data = original
        AnnexB.convertToLengthPrefixed(&data)
        try AnnexB.convertInPlace(&data, nalLengthSize: 4)
        XCTAssertEqual(data, original)
    }

    func testConvertWithoutStartCodeLeavesTheBufferAlone() {
        var data = Data([0x01, 0x02, 0x03])
        AnnexB.convertToLengthPrefixed(&data)
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }
}

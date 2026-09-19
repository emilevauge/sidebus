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

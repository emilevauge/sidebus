import XCTest

@testable import SidebusCore

final class ContactBookTests: XCTestCase {

    func testParsesTheContactsMessage() {
        let text = "Jérôme\t(0033)664217960\t0\nDupont, Marie\t06 12 34 56 78\t1\nDupont, Marie\t0612345678\t1\n"
        XCTAssertEqual(ContactBook.parse(lines: text), [
            PhoneContact(name: "Jérôme", number: "(0033)664217960"),
            PhoneContact(name: "Dupont, Marie", number: "06 12 34 56 78", isStarred: true),
        ])
    }

    func testReadsThePhotoIDWhenThePhoneSendsOne() {
        let text = "Ada\t0600000001\t0\t812\nBob\t0600000002\t0\t\nEve\t0600000003\t0\tx\n"
        XCTAssertEqual(ContactBook.parse(lines: text).map(\.photoID), ["812", nil, nil])
    }

    func testDialableKeepsOnlyWhatThePhoneDials() {
        XCTAssertEqual(ContactBook.dialable("(0033) 6.64-21 79 60"), "0033664217960")
        XCTAssertEqual(ContactBook.dialable("+33 6 12"), "+33612")
    }

    func testSearchRanksNamePrefixesFirstAndIgnoresAccents() {
        let contacts = [
            PhoneContact(name: "Marc Jerome", number: "0600000001"),
            PhoneContact(name: "Jérôme", number: "0600000002"),
            PhoneContact(name: "Benjamin", number: "0600000003"),
        ]
        XCTAssertEqual(ContactBook.search("jero", in: contacts).map(\.name), ["Jérôme", "Marc Jerome"])
        XCTAssertEqual(ContactBook.search("jam", in: contacts).map(\.name), ["Benjamin"])
    }

    func testSearchFindsANationalNumberInAnInternationalOne() {
        let contacts = [PhoneContact(name: "Jérôme", number: "(0033)664217960")]
        XCTAssertEqual(ContactBook.search("0664", in: contacts).map(\.name), ["Jérôme"])
    }

    func testNamesAnIncomingNumber() {
        let contacts = [PhoneContact(name: "Jérôme", number: "06 64 21 79 60")]
        XCTAssertEqual(ContactBook.contact(for: "+33664217960", in: contacts)?.name, "Jérôme")
        XCTAssertNil(ContactBook.contact(for: "+33600000000", in: contacts))
    }
}

final class CallMessageTests: XCTestCase {

    func testCallMessagesSurviveARoundTrip() throws {
        let messages: [Message] = [
            .callAccess(token: Data(repeating: 7, count: 32)),
            .callAccess(token: Data()),
            .callGrant(status: .granted, token: Data(repeating: 9, count: 32)),
            .callGrant(status: .waiting, token: Data()),
            .callStatus(flags: 0b11),
            .callStart,
            .callStop,
            .callAudio(Data([1, 2, 3, 4])),
            .contactsRequest,
            .contacts(Data("Jérôme\t0612\t1\n".utf8)),
            .callerID(Data("Spam probable\nAppel entrant".utf8)),
            .photosRequest(Data("12\n34".utf8)),
            .photo(id: 4242, image: Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        var decoder = MessageDecoder()
        for message in messages { decoder.append(MessageCodec.encode(message)) }
        for message in messages { XCTAssertEqual(try decoder.next(), message) }
    }
}

final class CallingCodeTests: XCTestCase {

    func testFindsTheCountryOfAnInternationalNumber() {
        XCTAssertEqual(CallingCode.region(of: "+1 415 555 0100"), "US")
        XCTAssertEqual(CallingCode.region(of: "+33 6 71 23 39 49"), "FR")
        XCTAssertEqual(CallingCode.region(of: "0044 20 7946 0000"), "GB")
        XCTAssertEqual(CallingCode.region(of: "+352 621 000 000"), "LU")
    }

    func testANationalNumberIsFromHome() {
        XCTAssertEqual(CallingCode.region(of: "06 71 23 39 49", home: "FR"), "FR")
    }

    func testDrawsTheFlag() {
        XCTAssertEqual(CallingCode.flag("FR"), "🇫🇷")
    }
}

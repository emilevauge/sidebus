import XCTest

@testable import SidebusCore

final class ContactBookTests: XCTestCase {

    func testParsesTheProviderOutput() throws {
        let output = """
            Row: 0 name=Jérôme, number=(0033)664217960, starred=0, times_contacted=0
            Row: 1 name=Dupont, Marie, number=06 12 34 56 78, starred=1, times_contacted=4
            Row: 2 name=Dupont, Marie, number=0612345678, starred=1, times_contacted=4
            """
        let contacts = try XCTUnwrap(ContactBook.parse(output))
        XCTAssertEqual(contacts, [
            PhoneContact(name: "Jérôme", number: "(0033)664217960"),
            PhoneContact(name: "Dupont, Marie", number: "06 12 34 56 78", isStarred: true),
        ])
    }

    func testReportsTheMissingPermission() {
        XCTAssertNil(ContactBook.parse("Row: 0 permission=0"))
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

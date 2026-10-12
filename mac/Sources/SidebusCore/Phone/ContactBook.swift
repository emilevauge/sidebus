import Foundation

/// One number of a contact in the phone's address book.
public struct PhoneContact: Sendable, Hashable, Identifiable {
    public let name: String
    public let number: String
    public let isStarred: Bool

    public var id: String { name + "\u{0}" + number }

    public init(name: String, number: String, isStarred: Bool = false) {
        self.name = name
        self.number = number
        self.isStarred = isStarred
    }
}

/// The phone's address book, as the Android app hands it over adb, and the search the
/// dialer runs on it.
public enum ContactBook {

    /// Parses `content query --uri content://app.sidebus.contacts/phones`: one
    /// `Row: <n> name=<name>, number=<number>, starred=<0|1>, times_contacted=<n>` line
    /// per number. Returns nil when the app reports the contacts permission missing.
    ///
    /// The keys are found from the right, since a name may hold a comma but the number and
    /// the counters never do.
    public static func parse(_ output: String) -> [PhoneContact]? {
        var contacts: [PhoneContact] = []
        for line in output.split(separator: "\n") {
            if line.contains("permission=0") { return nil }
            guard let nameStart = line.range(of: " name="),
                  let numberStart = line.range(of: ", number=", options: .backwards),
                  let starredStart = line.range(of: ", starred=", options: .backwards),
                  nameStart.upperBound <= numberStart.lowerBound,
                  numberStart.upperBound <= starredStart.lowerBound
            else { continue }
            let name = String(line[nameStart.upperBound..<numberStart.lowerBound])
            let number = String(line[numberStart.upperBound..<starredStart.lowerBound])
            let starred = line[starredStart.upperBound...].hasPrefix("1")
            guard !number.isEmpty, number != "NULL" else { continue }
            contacts.append(PhoneContact(name: name == "NULL" ? number : name, number: number, isStarred: starred))
        }
        // The same number saved twice under one name shows once.
        var seen = Set<String>()
        return contacts.filter { seen.insert($0.name + "\u{0}" + dialable($0.number)).inserted }
    }

    /// The number as the phone dials it: digits, `+`, `*` and `#`, nothing else.
    public static func dialable(_ number: String) -> String {
        String(number.filter { $0.isASCII && ($0.isNumber || "+*#".contains($0)) })
    }

    /// Contacts matching what is typed, best first: a name starting with the query, then a
    /// word of the name starting with it, then a number containing its digits. Case and
    /// accents do not count. Starred contacts go first within each group.
    public static func search(_ query: String, in contacts: [PhoneContact], limit: Int = 8) -> [PhoneContact] {
        let needle = folded(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }
        let digits = dialable(query)

        func rank(_ contact: PhoneContact) -> Int? {
            let name = folded(contact.name)
            if name.hasPrefix(needle) { return 0 }
            if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(needle) }) {
                return 1
            }
            if name.contains(needle) { return 2 }
            if digits.count >= 3, matchesDigits(contact.number, digits) { return 3 }
            return nil
        }

        return contacts
            .compactMap { contact in rank(contact).map { (contact, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.isStarred != b.0.isStarred { return a.0.isStarred }
                return a.0.name.localizedCompare(b.0.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The contact a number belongs to, to name an incoming call. The last nine digits
    /// decide, so that 06 12 34 56 78 and +33 6 12 34 56 78 are the same number.
    public static func contact(for number: String, in contacts: [PhoneContact]) -> PhoneContact? {
        let tail = String(dialable(number).filter(\.isNumber).suffix(9))
        guard tail.count == 9 else { return nil }
        return contacts.first { String(dialable($0.number).filter(\.isNumber).suffix(9)) == tail }
    }

    private static func matchesDigits(_ number: String, _ digits: String) -> Bool {
        let plain = dialable(number)
        if plain.contains(digits) { return true }
        // A national number typed against an international one, or the reverse: 0612...
        // against +33612... or 0033612...
        let typed = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        return typed.count >= 3 && plain.contains(typed)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

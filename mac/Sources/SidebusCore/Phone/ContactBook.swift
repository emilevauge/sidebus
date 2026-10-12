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

    /// Parses the CONTACTS message (`protocol/PROTOCOL.md` 10.5): one line per number,
    /// name, tab, number, tab, starred as 0 or 1.
    public static func parse(lines text: String) -> [PhoneContact] {
        let contacts = text.split(separator: "\n").compactMap { line -> PhoneContact? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[1].isEmpty else { return nil }
            return PhoneContact(
                name: fields[0].isEmpty ? String(fields[1]) : String(fields[0]),
                number: String(fields[1]),
                isStarred: fields.count > 2 && fields[2] == "1"
            )
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

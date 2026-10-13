import AppKit
import SidebusCore
import SwiftUI

/// A contact's photo, from the phone, or their initials on a tinted disc without one.
struct ContactAvatar: View {
    let name: String?
    let photoID: String?
    let size: CGFloat
    /// Read so that the view redraws as photos come in.
    let photosVersion: Int

    var body: some View {
        ZStack {
            if let image = photoID.flatMap(Self.image) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Self.tint(for: name ?? ""))
                if let initials = Self.initials(name) {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id(photosVersion)
    }

    private static let cache = NSCache<NSString, NSImage>()

    private static func image(_ id: String) -> NSImage? {
        if let image = cache.object(forKey: id as NSString) { return image }
        guard let data = ContactPhotos.image(for: id), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    /// "Ada Lovelace" gives "AL"; a number, or nothing, gives none.
    static func initials(_ name: String?) -> String? {
        guard let name, name.contains(where: \.isLetter) else { return nil }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }

    private static let tints: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .brown]

    /// Same name, same color, from one launch to the next.
    private static func tint(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[sum % tints.count].opacity(0.75)
    }
}

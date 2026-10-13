import Foundation

/// The contacts' photos, kept on disk once the phone sent them (`protocol/PROTOCOL.md`
/// 10.7), so that a check asks only for the new ones.
public enum ContactPhotos {

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("app.sidebus/ContactPhotos", isDirectory: true)
    }()

    private static func file(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".jpg")
    }

    /// The JPEG for a photo id, nil when it is not here or the phone had none.
    public static func image(for id: String) -> Data? {
        guard let data = try? Data(contentsOf: file(id)), !data.isEmpty else { return nil }
        return data
    }

    /// The photo ids of `contacts` not asked for yet.
    public static func missing(in contacts: [PhoneContact]) -> [String] {
        let ids = Set(contacts.compactMap(\.photoID))
        return ids.filter { !FileManager.default.fileExists(atPath: file($0).path) }.sorted()
    }

    /// Keeps a photo the phone sent. An empty one is kept too, as a mark not to ask again.
    public static func save(_ image: Data, for id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.write(to: file(id), options: .atomic)
    }

    /// Deletes the photos no contact names any more.
    public static func prune(keeping contacts: [PhoneContact]) {
        let ids = Set(contacts.compactMap(\.photoID))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

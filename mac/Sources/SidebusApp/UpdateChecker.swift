import AppKit
import Foundation
import Observation
import os

/// Asks the GitHub releases API whether a newer Sidebus exists.
///
/// Two entry points. `startPeriodicCheck` runs at launch, then every 24 hours, and again on
/// wake from sleep: a `Timer` does not tick while the Mac is asleep, so a long sleep would
/// otherwise skip a day. All paths share the same cooldown, so rapid restarts and
/// back to back wake events never hammer the API.
///
/// `checkManually` serves the Settings button. It always hits the network and always
/// returns something, including the failure.
///
/// Unlike a background agent, Sidebus lives in the menu bar and the user opens it. A found
/// update therefore shows up as a row in that menu rather than as a system notification,
/// which keeps one permission out of the picture.
@MainActor
@Observable
final class UpdateChecker {

    private static let owner = "emilevauge"
    private static let repo = "sidebus"

    /// Minimum delay between two background checks.
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckedKey = "lastUpdateCheckedAt"

    struct Release: Sendable, Equatable {
        let version: String
        let pageURL: URL
        /// Set when the release carries a `Sidebus.dmg` asset, which is what the self
        /// updater needs. Without it the menu can only open the release page.
        let dmgURL: URL?
    }

    enum ManualResult: Equatable {
        case upToDate(current: String)
        case newer(Release)
        case failed(String)
    }

    /// Newer release found by any check, or `nil`. The menu reads this.
    private(set) var available: Release?
    private(set) var isChecking = false
    private(set) var lastManualResult: ManualResult?

    @ObservationIgnored
    private var timer: Timer?
    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "update")

    /// Version of the running bundle. `swift run` has no bundle and no reliable version,
    /// hence the fallback, which also keeps the checker quiet during development.
    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }

    init() {
        startPeriodicCheck()
    }

    /// Armed from `init`, and not from a window's `task`: the settings window may never be
    /// opened, and the check has to run anyway.
    private func startPeriodicCheck() {
        // A raw SwiftPM binary has no bundle identifier and no version: nothing sensible to
        // compare against, so no check at all.
        guard Bundle.main.bundleIdentifier != nil else { return }

        Task { await maybeCheck() }

        timer?.invalidate()
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
    }

    private func checkSoon() {
        Task { await maybeCheck() }
    }

    /// Honours the cooldown, so restarts and wake events do not pile up requests.
    private func maybeCheck() async {
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date,
            now.timeIntervalSince(last) < Self.checkInterval {
            return
        }
        UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)

        guard let release = try? await fetchLatest().get(), isNewer(release.version, than: currentVersion)
        else { return }
        log.info("update available: \(release.version, privacy: .public)")
        available = release
    }

    /// Does not touch the cooldown: a click always reaches the network.
    func checkManually() async {
        isChecking = true
        lastManualResult = nil
        defer { isChecking = false }

        let release: Release
        switch await fetchLatest() {
        case let .success(found):
            release = found
        case let .failure(reason):
            lastManualResult = .failed(reason.message)
            return
        }
        if isNewer(release.version, than: currentVersion) {
            available = release
            lastManualResult = .newer(release)
        } else {
            available = nil
            lastManualResult = .upToDate(current: currentVersion)
        }
    }

    /// Runs the self update when the release carries a DMG, opens the release page
    /// otherwise.
    func install() {
        guard let release = available else { return }
        guard let dmgURL = release.dmgURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        Task { await SelfUpdater.run(dmgURL: dmgURL, version: release.version) }
    }

    func openReleasePage() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: - GitHub

    /// Why no release came back, said as it is: GitHub answering 404 is no network
    /// trouble (a private repository, say, or no release yet).
    struct LookupError: Error {
        let message: String
    }

    private func fetchLatest() async -> Result<Release, LookupError> {
        let endpoint = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: endpoint) else { return .failure(LookupError(message: "bad release address")) }

        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sidebus/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            return .failure(LookupError(message: "could not reach github.com"))
        }
        switch http.statusCode {
        case 200: break
        case 404: return .failure(LookupError(message: "no release found on GitHub"))
        case 403, 429: return .failure(LookupError(message: "GitHub limits requests, try again later"))
        default: return .failure(LookupError(message: "GitHub answered \(http.statusCode)"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else {
            return .failure(LookupError(message: "unreadable answer from GitHub"))
        }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (object["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases/latest")!

        let dmg = (object["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String) == "Sidebus.dmg" }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))

        return .success(Release(version: version, pageURL: page, dmgURL: dmg))
    }

    /// Compares two dotted versions, missing components counting as zero.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").compactMap { Int($0) }
        let right = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

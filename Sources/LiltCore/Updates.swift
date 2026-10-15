import Foundation

/// A dotted numeric version such as "0.1.2", with an optional leading "v" as in a release tag.
/// Anything else, such as a "-beta" suffix, is not a version Lilt offers to install.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            // ASCII digits only: Character.isNumber also accepts other scripts' digits, which Int() then refuses anyway.
            guard (1...6).contains(piece.utf8.count), piece.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }
    /// "0.1" and "0.1.0" are the same release.
    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let count = max(a.parts.count, b.parts.count)
        return (a.parts + Array(repeating: 0, count: count - a.parts.count), b.parts + Array(repeating: 0, count: count - b.parts.count))
    }
    public static func == (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x == y }
    public static func < (a: AppVersion, b: AppVersion) -> Bool { let (x, y) = padded(a, b); return x.lexicographicallyPrecedes(y) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// A published Lilt release that can be installed in place of the running one.
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    /// The disk image `scripts/package.sh` builds, as attached to the GitHub release.
    public var asset: URL
    public var size: Int
    /// Lowercase hex SHA-256 that GitHub computed when the image was uploaded. Nil when the release does not list one.
    public var sha256: String?
    /// The release page, for reading the notes or downloading by hand.
    public var page: URL
    public var notes: String
    public init(version: AppVersion, asset: URL, size: Int, sha256: String?, page: URL, notes: String) {
        self.version = version; self.asset = asset; self.size = size; self.sha256 = sha256; self.page = page; self.notes = notes
    }
}

/// Where Lilt looks for a newer version of itself, and what it accepts from there.
/// Releases are read from GitHub, the only place Lilt is published; the request carries no account data.
public enum UpdateFeed {
    public static let bundleIdentifier = "app.lilt.desktop"
    /// The list rather than `/releases/latest`: every Lilt release so far is a research preview published as a
    /// pre-release, and `latest` leaves those out.
    public static let releases = URL(string: "https://api.github.com/repos/ShawnRyan2365/Lilt/releases?per_page=10")!
    /// The 0.1 images are about 2.5 MB. Anything far larger is not one of them.
    public static let maximumSize = 200 * 1024 * 1024
    /// How often the running app asks, when automatic checks are on.
    public static let interval: TimeInterval = 6 * 3600

    public enum Failure: Error, Equatable { case malformed }

    /// The newest published release that is newer than `current`, or nil when there is none.
    /// Drafts are skipped. A release only counts when it carries an image named for its own version, so a tag
    /// without one, or with an image for some other version, is never offered.
    public static func newest(in data: Data, after current: AppVersion) throws -> UpdateRelease? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.malformed }
        return list.compactMap(release).filter { $0.version > current }.max { $0.version < $1.version }
    }

    static func release(_ object: [String: Any]) -> UpdateRelease? {
        guard object["draft"] as? Bool == false,
              let tag = object["tag_name"] as? String, let version = AppVersion(tag),
              let pageText = object["html_url"] as? String, let page = URL(string: pageText), allowsDownload(from: page),
              let assets = object["assets"] as? [[String: Any]] else { return nil }
        let name = "Lilt-\(version).dmg"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
              (asset["state"] as? String).map({ $0 == "uploaded" }) ?? true,
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)), allowsDownload(from: link),
              let size = asset["size"] as? Int, size > 0, size <= maximumSize else { return nil }
        // A digest that is present but unreadable means something changed on the other side; offer nothing rather than skip the check.
        var sha256: String?
        if let digest = asset["digest"] as? String {
            guard let hex = Self.sha256(fromDigest: digest) else { return nil }
            sha256 = hex
        }
        return UpdateRelease(version: version, asset: link, size: size, sha256: sha256, page: page, notes: object["body"] as? String ?? "")
    }

    /// GitHub writes asset digests as "sha256:<64 hex digits>".
    public static func sha256(fromDigest digest: String) -> String? {
        guard digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst(7).lowercased()
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return hex
    }

    /// Release requests may only go to, or be redirected to, GitHub over HTTPS. Assets are served from
    /// `release-assets.githubusercontent.com` after a redirect from `github.com`.
    public static func allowsDownload(from url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "api.github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Why the running copy cannot be replaced where it is, or nil when it can as far as its path tells.
    /// Whether the folder is writable is a question for the file system, asked separately.
    public static func installBlocker(bundlePath path: String) -> String? {
        guard path.hasSuffix(".app") else { return "这是开发版本，没有可替换的应用" }
        // Gatekeeper runs a downloaded app that was never moved from a randomised, read-only copy.
        if path.contains("/AppTranslocation/") { return "请先把 Lilt 拖进“应用程序”再打开，然后再更新" }
        return nil
    }

    /// Whether an unpacked app is the release it claims to be: Lilt, at exactly that version.
    public static func matches(info: [String: Any], version: AppVersion) -> Bool {
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == "Lilt",
              let text = info["CFBundleShortVersionString"] as? String, let found = AppVersion(text) else { return false }
        return found == version
    }

    /// Whether an automatic check is due.
    public static func due(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards would otherwise postpone the next check for as long as it is behind.
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}

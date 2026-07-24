import Foundation

/// A released version, compared numerically rather than as text.
/// "v0.10.0" is newer than "v0.9.0"; string comparison gets that backwards.
public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let components: [Int]
    public let raw: String

    /// Accepts "v1.2.3", "1.2", "v2.0.0-beta.1". Pre-release suffixes are
    /// dropped for ordering, so 1.0.0-beta and 1.0.0 compare equal.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        if let dash = body.firstIndex(of: "-") { body = String(body[body.startIndex..<dash]) }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        self.components = numbers
        self.raw = trimmed
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            // Absent trailing components are zero, so 1.2 == 1.2.0.
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(version: String, url: URL)
    /// The check could not be completed. Never surfaced as "you are up to date",
    /// because a failed request is not evidence of anything.
    case failed(String)
}

public enum UpdateCheck {
    public static let releasesAPI = URL(string:
        "https://api.github.com/repos/cyburke/hey-codex/releases/latest")!
    public static let releasesPage = URL(string:
        "https://github.com/cyburke/hey-codex/releases/latest")!

    /// Decide what a fetched tag means for the running build.
    public static func status(currentVersion: String,
                              latestTag: String?,
                              releaseURL: URL?) -> UpdateStatus {
        guard let latestTag, let latest = ReleaseVersion(latestTag) else {
            return .failed("Could not read the latest version.")
        }
        guard let current = ReleaseVersion(currentVersion) else {
            return .failed("This build has no version number.")
        }
        guard current < latest else { return .upToDate }
        return .available(version: latest.raw, url: releaseURL ?? releasesPage)
    }

    /// Pull `tag_name` and `html_url` out of a GitHub release payload.
    public static func parse(_ data: Data) -> (tag: String?, url: URL?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let tag = object["tag_name"] as? String
        let url = (object["html_url"] as? String).flatMap(URL.init(string:))
        return (tag, url)
    }

    /// Whether enough time has passed to check again without being a nuisance.
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = 24 * 60 * 60) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

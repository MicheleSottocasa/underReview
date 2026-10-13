import Foundation

/// A published ReviewDesk release.
public struct AppRelease: Equatable, Sendable {
    /// Without the tag's leading "v".
    public var version: String
    public var url: String
    public var publishedAt: Date?
    public var notes: String
    /// The `.dmg` attached to the release, if any: what the in-app update installs.
    public var installer: Installer?

    public struct Installer: Equatable, Sendable {
        public var name: String
        /// GitHub's checksum of the file, `sha256:<hex>`, when it publishes one.
        public var digest: String?
    }

    public init(version: String, url: String, publishedAt: Date?, notes: String, installer: Installer? = nil) {
        (self.version, self.url, self.publishedAt, self.notes, self.installer) = (version, url, publishedAt, notes, installer)
    }
}

public enum AppVersion {
    /// Where releases are published (public, so any `gh` login can read it).
    public static let repository = "MicheleSottocasa/underReview"
    public static let checkInterval: TimeInterval = 6 * 60 * 60

    /// Numeric, part by part: 0.10.0 is newer than 0.9.3. Missing parts count as 0, a "v" prefix and
    /// non-numeric suffixes ("-beta") are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

extension GitHub {
    /// The newest published release (GitHub's "latest" skips drafts and pre-releases).
    public func latestRelease(repo: String) async throws -> AppRelease {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/releases/latest"])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = json["tag_name"] as? String else {
            throw GitHubError.notFound("Latest release of \(repo)")
        }
        let dmg = (json["assets"] as? [[String: Any]] ?? []).first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        return AppRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: json["html_url"] as? String ?? "",
                          publishedAt: Self.date(json["published_at"]), notes: json["body"] as? String ?? "",
                          installer: dmg.map { AppRelease.Installer(name: $0["name"] as? String ?? "", digest: $0["digest"] as? String) })
    }
}

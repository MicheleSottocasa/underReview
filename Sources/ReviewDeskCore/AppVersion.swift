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

/// What one version changed: its CHANGELOG.md section, or its release description.
public struct VersionNotes: Equatable, Sendable, Identifiable {
    public var version: String
    public var date: Date?
    public var notes: String

    public var id: String { version }

    public init(version: String, date: Date? = nil, notes: String) {
        (self.version, self.date, self.notes) = (version, date, notes)
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

    /// What to show at launch.
    public enum LaunchNotes: Equatable, Sendable {
        /// The changes since this version, the one that ran before.
        case since(String)
        /// This version's own section: an existing user updating from a version that didn't record itself.
        case thisVersion
    }

    /// At launch: the changes since the version that ran before, when this build is newer. Without a recorded
    /// version, an existing user (`existingUser`: the tour was seen) gets this version's notes and a fresh install
    /// nothing (the tour covers it). Never for a `dev` build or the same version.
    public static func launchNotes(lastLaunched: String?, current: String, existingUser: Bool) -> LaunchNotes? {
        guard current != "dev" else { return nil }
        guard let lastLaunched else { return existingUser ? .thisVersion : nil }
        return isNewer(current, than: lastLaunched) ? .since(lastLaunched) : nil
    }

    /// The `## <version>` sections of a changelog (the headings `scripts/release-notes.sh` reads) in
    /// (installed, latest], newest first.
    public static func notes(in changelog: String, after installed: String, through latest: String) -> [VersionNotes] {
        var sections: [VersionNotes] = []
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                sections.append(VersionNotes(version: line.dropFirst(3).trimmingCharacters(in: .whitespaces), notes: ""))
            } else if !sections.isEmpty {
                sections[sections.count - 1].notes += line + "\n"
            }
        }
        for index in sections.indices { sections[index].notes = sections[index].notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        return inRange(sections, after: installed, through: latest)
    }

    /// Versions newer than `installed` and not newer than `latest`, newest first. "Unreleased" counts as 0, so it's left out.
    static func inRange(_ notes: [VersionNotes], after installed: String, through latest: String) -> [VersionNotes] {
        notes.filter { isNewer($0.version, than: installed) && !isNewer($0.version, than: latest) }
            .sorted { isNewer($0.version, than: $1.version) }
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

    /// What changed in (installed, latest], newest first: CHANGELOG.md at the latest tag, dated from the releases.
    /// When the changelog can't be read or has none of those versions, the releases' own descriptions.
    public func releaseNotes(repo: String, after installed: String, through latest: String) async throws -> [VersionNotes] {
        let releases = try? await publishedReleases(repo: repo)
        let changelog: [VersionNotes]
        do {
            let data = try await runner.output("gh", ["api", "-H", "Accept: application/vnd.github.raw",
                                                      "repos/\(repo)/contents/CHANGELOG.md?ref=v\(latest)"])
            changelog = AppVersion.notes(in: String(decoding: data, as: UTF8.self), after: installed, through: latest)
        } catch {
            guard let releases else { throw error }
            return AppVersion.inRange(releases, after: installed, through: latest)
        }
        guard !changelog.isEmpty else { return AppVersion.inRange(releases ?? [], after: installed, through: latest) }
        let dates = Dictionary((releases ?? []).map { ($0.version, $0.date) }, uniquingKeysWith: { first, _ in first })
        return changelog.map { entry in
            var entry = entry
            entry.date = dates[entry.version] ?? nil
            return entry
        }
    }

    /// Published releases (no drafts or pre-releases), as GitHub lists them.
    func publishedReleases(repo: String) async throws -> [VersionNotes] {
        let data = try await runner.output("gh", ["api", "repos/\(repo)/releases?per_page=100"])
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw GitHubError.notFound("Releases of \(repo)")
        }
        return list.compactMap { json in
            guard let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
            return VersionNotes(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, date: Self.date(json["published_at"]),
                                notes: json["body"] as? String ?? "")
        }
    }
}

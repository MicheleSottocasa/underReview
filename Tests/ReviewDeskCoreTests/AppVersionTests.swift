import Foundation
import Testing
@testable import ReviewDeskCore

@Test func comparesVersionsNumerically() {
    #expect(AppVersion.isNewer("0.10.0", than: "0.9.3"))
    #expect(AppVersion.isNewer("v0.3.0", than: "0.2.0"))
    #expect(AppVersion.isNewer("1.0", than: "0.99.99"))
    #expect(!AppVersion.isNewer("0.2.0", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.2", than: "0.2.0"))   // missing parts are 0
    #expect(!AppVersion.isNewer("0.1.9", than: "0.2.0"))
    #expect(!AppVersion.isNewer("0.2.0-beta", than: "0.2.0"))
}

@Test func aReleaseIsNewerThanItsPreReleases() {
    #expect(AppVersion.isNewer("0.10.0", than: "0.10.0-beta.1"))
    #expect(AppVersion.isNewer("0.10.0-beta.2", than: "0.10.0-beta.1"))
    #expect(AppVersion.isNewer("0.10.0-beta.10", than: "0.10.0-beta.9"))
    #expect(AppVersion.isNewer("0.10.0-beta.1", than: "0.9.7"))
    #expect(!AppVersion.isNewer("0.10.0-beta.1", than: "0.10.0-beta.1"))
    #expect(!AppVersion.isNewer("0.9.8", than: "0.10.0-beta.1"))
}

@Test func readsTheLatestRelease() async throws {
    let runner = FakeRunner { _ in
        ok(#"{"tag_name":"v0.3.0","html_url":"https://github.com/o/r/releases/tag/v0.3.0","published_at":"2026-10-20T09:00:00Z","body":"Notes"}"#)
    }
    let release = try await GitHub(runner: runner).latestRelease(repo: "o/r")
    #expect(release == AppRelease(version: "0.3.0", url: "https://github.com/o/r/releases/tag/v0.3.0",
                                  publishedAt: try Date("2026-10-20T09:00:00Z", strategy: .iso8601), notes: "Notes"))
    #expect(runner.calls.first?.args == ["api", "repos/o/r/releases/latest"])
}

private let changelog = """
# Changelog

Intro text.

## Unreleased

- Not out yet.

## 0.6.0

- Six.
## 0.5.0

- Five, line one.
- Five, line two.

## 0.3.0

- Three.

## 0.2.0

- Two.
"""

@Test func slicesTheChangelogBetweenTwoVersions() {
    // 0.4.0 has no section (skipped release): the range still works around it.
    let notes = AppVersion.notes(in: changelog, after: "0.2.0", through: "0.5.0")
    #expect(notes == [VersionNotes(version: "0.5.0", notes: "- Five, line one.\n- Five, line two."),
                      VersionNotes(version: "0.3.0", notes: "- Three.")])
    #expect(AppVersion.notes(in: changelog, after: "0.4.1", through: "0.6.0").map(\.version) == ["0.6.0", "0.5.0"])
    #expect(AppVersion.notes(in: changelog, after: "0.6.0", through: "0.6.0").isEmpty)
    #expect(AppVersion.notes(in: "no sections", after: "0.1.0", through: "0.6.0").isEmpty)
}

@Test func showsChangesOnlyAfterAnUpdate() {
    func notes(_ last: String?, _ current: String, existingUser: Bool = true) -> AppVersion.LaunchNotes? {
        AppVersion.launchNotes(lastLaunched: last, current: current, existingUser: existingUser)
    }
    #expect(notes("0.7.1", "0.8.1") == .since("0.7.1"))
    #expect(notes(nil, "0.8.1", existingUser: false) == nil)   // fresh install: the tour covers it
    #expect(notes(nil, "0.8.1") == .thisVersion)               // updated from a version that didn't record itself
    #expect(notes("0.8.1", "0.8.1") == nil)
    #expect(notes("0.9.0", "0.8.1") == nil)                    // downgrade
    #expect(notes("0.7.1", "dev") == nil)
    #expect(notes(nil, "dev") == nil)
}

@Test func readsReleaseNotesFromTheChangelogAtTheLatestTag() async throws {
    let runner = FakeRunner { call in
        if call.args.last!.hasPrefix("repos/o/r/releases") {
            return ok(#"[{"tag_name":"v0.6.0","published_at":"2026-10-20T09:00:00Z","body":"Release six"},"#
                      + #"{"tag_name":"v0.5.0","published_at":"2026-10-10T09:00:00Z","body":"Release five"}]"#)
        }
        return ok(changelog)
    }
    let notes = try await GitHub(runner: runner).releaseNotes(repo: "o/r", after: "0.3.0", through: "0.6.0")
    #expect(notes == [VersionNotes(version: "0.6.0", date: try Date("2026-10-20T09:00:00Z", strategy: .iso8601), notes: "- Six."),
                      VersionNotes(version: "0.5.0", date: try Date("2026-10-10T09:00:00Z", strategy: .iso8601),
                                   notes: "- Five, line one.\n- Five, line two.")])
    #expect(runner.calls.contains { $0.args.last == "repos/o/r/contents/CHANGELOG.md?ref=v0.6.0" })
}

@Test func fallsBackToReleaseDescriptionsWithoutAChangelog() async throws {
    let runner = FakeRunner { call in
        if call.args.last!.hasPrefix("repos/o/r/releases") {
            return ok(#"[{"tag_name":"v0.7.0","prerelease":true,"body":"Beta"},{"tag_name":"v0.6.0","body":"Release six"},"#
                      + #"{"tag_name":"v0.5.0","body":"Release five"},{"tag_name":"v0.3.0","body":"Release three"}]"#)
        }
        return CommandResult(status: 1, stdout: Data(), stderr: "HTTP 404: Not Found")
    }
    let notes = try await GitHub(runner: runner).releaseNotes(repo: "o/r", after: "0.3.0", through: "0.6.0")
    #expect(notes.map(\.notes) == ["Release six", "Release five"])
}

@Test func reportsTheErrorWhenNothingCanBeRead() async {
    let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(), stderr: "HTTP 404: Not Found") }
    await #expect(throws: (any Error).self) {
        try await GitHub(runner: runner).releaseNotes(repo: "o/r", after: "0.3.0", through: "0.6.0")
    }
}

@Test func feedbackOpensAPrefilledIssueOnTheAppsRepository() throws {
    let url = try #require(Feedback.problem.issueURL(version: "0.9.8", macOS: "14.5.0", providers: ["Claude Code", "Ollama"]))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "github.com" && components.path == "/MicheleSottocasa/underReview/issues/new")
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(items["title"] == "Problem: ")
    #expect(items["body"]?.hasPrefix("**What happened?**") == true)
    #expect(items["body"]?.hasSuffix("---\nReviewDesk 0.9.8 · macOS 14.5.0 · AI: Claude Code, Ollama\n") == true)
    #expect(Feedback.feature.issueURL(version: "dev", macOS: "15.0.0", providers: [])?.absoluteString.contains("title=Feature%3A%20") == true)
}

@Test func feedbackEncodesEverythingAQueryWouldMisread() throws {
    let url = try #require(Feedback.feature.issueURL(version: "1+1&x=y#z", macOS: "14", providers: ["C++"]))
    let query = try #require(url.query)
    #expect(!query.contains("+") && !query.contains("#") && query.components(separatedBy: "&").count == 2)
    #expect(query.contains("1%2B1%26x%3Dy%23z") && query.contains("%0A") && query.contains("C%2B%2B"))
}

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

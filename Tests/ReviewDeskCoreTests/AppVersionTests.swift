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

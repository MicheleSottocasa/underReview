import Foundation
import Testing
@testable import ReviewDeskCore

@Test func readsTextFilesInsideTheFolderOnly() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("rd-context-\(UUID().uuidString)")
    let root = base.appendingPathComponent("docs"), outside = base.appendingPathComponent("secret.txt")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("# API".utf8).write(to: root.appendingPathComponent("api.md"))
    try Data("nested".utf8).write(to: root.appendingPathComponent("sub/notes.txt"))
    try Data("TOKEN=1".utf8).write(to: root.appendingPathComponent(".env"))
    try Data([0x89, 0x50, 0x00, 0x01]).write(to: root.appendingPathComponent("logo.png"))
    try Data(repeating: 0x61, count: ProjectContext.maxFileBytes + 1).write(to: root.appendingPathComponent("big.txt"))
    try Data("password".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.md"), withDestinationURL: root.appendingPathComponent("api.md"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("env-link"), withDestinationURL: root.appendingPathComponent(".env"))

    let files = ProjectContext.readLocal(root.path)
    let byName = Dictionary(uniqueKeysWithValues: files.map { (String($0.path.split(separator: "/").suffix(2).joined(separator: "/")), $0) })
    #expect(byName["docs/api.md"]?.content == "# API" && byName["docs/api.md"]?.included == true)
    #expect(byName["sub/notes.txt"]?.content == "nested")
    #expect(byName["docs/alias.md"]?.content == "# API") // a link that stays inside is fine
    #expect(byName["docs/escape.txt"]?.excludedReason == "Links outside the folder" && byName["docs/escape.txt"]?.content == nil)
    #expect(byName["docs/logo.png"]?.excludedReason == "Binary file")
    #expect(byName["docs/big.txt"]?.excludedReason == "Larger than 100 KB" && byName["docs/big.txt"]?.included == false)
    #expect(byName["docs/.env"] == nil) // hidden files are never read
    #expect(byName["docs/env-link"]?.excludedReason == "Links to a hidden file" && byName["docs/env-link"]?.content == nil)
    // Full names, as chosen, even under /var (really /private/var) where the temporary folder lives.
    #expect(files.map(\.path).contains(root.path + "/sub/notes.txt") && files.allSatisfy { $0.path.hasPrefix(root.path + "/") })
    #expect(!files.contains { $0.content?.contains("password") == true || $0.content?.contains("TOKEN") == true })

    #expect(ProjectContext.readLocal(root.appendingPathComponent("api.md").path).map(\.content) == ["# API"])
    // Past the limit, enumeration stops: links count too, and one entry says more weren't read.
    let capped = ProjectContext.readLocal(root.path, limit: 3)
    #expect(capped.count == 4 && capped.last?.excludedReason == "More files not read (limit 3)")
    #expect(ProjectContext.readLocal(base.appendingPathComponent("missing").path).first?.excludedReason == "Not found")
    #expect(ProjectContext.folders([ContextSource(kind: .local, location: root.path), ContextSource(kind: .local, location: outside.path),
                                    ContextSource(kind: .repository, location: "o/r")]).count == 1)
    // Never the whole disk, the home folder or a folder above it, nor a path that would bend the deny rules.
    let home = base.appendingPathComponent("home")
    let odd = base.appendingPathComponent("a*b")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
    #expect(ProjectContext.folders(["/", home.path, base.path, odd.path, root.path].map { ContextSource(kind: .local, location: $0) },
                                   home: home.path).map { URL(fileURLWithPath: $0).lastPathComponent } == ["docs"])
}

@Test func readsARepositoryFolderAtARefAndListsWhatItLeavesOut() async throws {
    let runner = FakeRunner { call in
        if call.args.contains("graphql") {
            return data(#"{"repository":{"f0":{"text":"guide","isBinary":false,"isTruncated":false},"f1":{"text":null,"isBinary":true,"isTruncated":false}}}"#)
        }
        return ok(#"[{"path":"README.md","size":10},{"path":"docs/guide.md","size":5},{"path":"docs/diagram.png","size":40},{"path":"docs/dump.sql","size":500000}]"#)
    }
    let source = ContextSource(kind: .repository, location: "o/lib", path: "docs/", ref: "v2")
    let files = await ProjectContext.readRepository(source, github: GitHub(runner: runner))
    #expect(runner.calls.first?.args.prefix(2) == ["api", "repos/o/lib/git/trees/v2?recursive=1"])
    #expect(files.map(\.path) == ["o/lib@v2:docs/diagram.png", "o/lib@v2:docs/dump.sql", "o/lib@v2:docs/guide.md"])
    var main = source
    main.ref = ""
    #expect(await ProjectContext.readRepository(main, github: GitHub(runner: runner)).map(\.path).contains("o/lib:docs/guide.md"))
    #expect(files.map(\.included) == [false, false, true] && files[2].content == "guide")
    #expect(files[1].excludedReason == "Larger than 100 KB")

    let failing = FakeRunner { _ in CommandResult(status: 1, stdout: Data(), stderr: "HTTP 404") }
    let failed = await ProjectContext.readRepository(ContextSource(kind: .repository, location: "o/gone"), github: GitHub(runner: failing))
    #expect(failed.count == 1 && failed[0].included == false && failed[0].excludedReason?.hasPrefix("Couldn't read it") == true)
    #expect(!ContextSource.isRepositoryName("o/r/../user") && !ContextSource.isRepositoryName("o") && ContextSource.isRepositoryName("my-org/my.repo"))
}

@Test func extraContextCountsAgainstTheBudgetAndGoesIntoThePrompts() {
    let doc = ContextFile(path: "~/docs/api.md", content: "```fences```\ncarefully", included: true)
    let left = ContextFile(path: "~/docs/big.md", content: String(repeating: "x", count: 400), included: true)
    let fitted = ProjectContext.fitting([doc, left], budget: doc.tokens + 10)
    #expect(fitted.map(\.included) == [true, false])

    let context = ReviewContext(title: "T", body: "B", files: [], budget: 1_000, extra: fitted)
    #expect(context.tokens == AIContext.estimateTokens("TB") + doc.tokens)
    let prompt = AIContext.prompt(context)
    #expect(prompt.contains("## Project context") && prompt.contains("### ~/docs/api.md\n````\n```fences```\ncarefully\n````"))
    #expect(!prompt.contains("~/docs/big.md"))
    #expect(!AIContext.prompt(ReviewContext(title: "T", body: "B", files: [], budget: 1)).contains("## Project context"))

    let comment = Comment(id: "c", author: "a", body: "Why?", createdAt: .now)
    #expect(AIContext.explainPrompt(title: "T", body: "B", path: nil, line: nil, patch: nil, conversation: [comment], comment: comment,
                                    extra: [doc]).contains("### ~/docs/api.md"))
}

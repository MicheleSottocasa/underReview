import Testing
@testable import ReviewDeskCore

private let python = Syntax.language(for: "settings.py")!

private func kinds(_ line: String, _ language: SyntaxLanguage = python) -> [String] {
    let chars = Array(line)
    return Syntax.tokens(line, language: language).map { "\($0.kind):\(String(chars[$0.range]))" }
}

@Test func highlightsCallsAndStrings() {
    #expect(kinds(#"AUTH0_MGMT_DOMAIN = env("AUTH0_MGMT_DOMAIN", default="")"#)
        == [#"call:env"#, #"string:"AUTH0_MGMT_DOMAIN""#, #"string:"""#])
}

@Test func commentsRunToEndOfLineButNotInsideStrings() {
    #expect(kinds("# Auth0 tenant") == ["comment:# Auth0 tenant"])
    #expect(kinds(#"x = "a # b"  # real"#) == [#"string:"a # b""#, "comment:# real"])
}

@Test func keywordsNumbersAndEscapes() {
    #expect(kinds("def f(x): return 42") == ["keyword:def", "call:f", "keyword:return", "number:42"])
    #expect(kinds(#"s = "say \"hi\"""#) == [#"string:"say \"hi\"""#])
    #expect(kinds("v2 = x1") == []) // digits inside identifiers aren't numbers
}

@Test func languageComesFromExtension() {
    #expect(Syntax.language(for: "App.swift")?.lineComments == ["//"])
    #expect(Syntax.language(for: "q.sql")?.lineComments == ["--"])
    #expect(Syntax.language(for: "README") == nil)
    let swift = Syntax.language(for: "a.swift")!
    #expect(kinds("let x = f() // done", swift) == ["keyword:let", "call:f", "comment:// done"])
}

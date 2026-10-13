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

@Test func docstringsSpanLinesAsStrings() {
    var open: String?
    let first = Syntax.tokens(#"    """"#, language: python, open: &open)
    #expect(first.map(\.kind) == [.string])
    #expect(open == #"""""#)
    // Words like `is` and `not` inside the docstring stay string, not keywords.
    let middle = Syntax.tokens("A missing account is hashed too, so timing does not reveal", language: python, open: &open)
    #expect(middle == [SyntaxToken(range: 0..<58, kind: .string)])
    let last = Syntax.tokens(#"    """  # done"#, language: python, open: &open)
    #expect(last.map(\.kind) == [.string, .comment])
    #expect(open == nil)
    #expect(kinds(#"x = """one line""" if y else 1"#) == [#"string:"""one line""""#, "keyword:if", "keyword:else", "number:1"])
}

@Test func diffSidesTrackOpenStringsSeparately() {
    let lines = Diff.parse("@@ -1,3 +1,3 @@\n-x = 1\n+doc = \"\"\"\n+is not code\n \"\"\"")
    let tokens = Syntax.tokens(diff: lines, language: python)
    #expect(tokens[lines[1]]?.map(\.kind) == [.number])  // removed side never opened a string
    #expect(tokens[lines[3]]?.map(\.kind) == [.string])  // added side is inside the docstring
    #expect(tokens[lines[4]]?.map(\.kind) == [.string])  // context closes it
}

import Foundation
import Testing
@testable import ReviewDeskCore

@Test func hexColorsParseAndPrint() {
    #expect(HexColor(hex: "#1E1F22") == HexColor(0x1E1F22))
    #expect(HexColor(hex: "1e1f22")?.hex == "#1E1F22")
    #expect(HexColor(hex: "#FFCC00D9") == HexColor(0xFFCC00, alpha: 0xD9))
    #expect(HexColor(hex: "#FFCC00D9")?.hex == "#FFCC00D9")
    #expect(HexColor(hex: "#abc") == HexColor(0xAABBCC))
    #expect(HexColor(hex: "#abc8") == HexColor(0xAABBCC, alpha: 0x88))
    for bad in ["", "#", "#12345", "#GGGGGG", "red", "#1234567"] { #expect(HexColor(hex: bad) == nil) }
    #expect(HexColor(red: 1, green: 0, blue: 0.5, alpha: 1).hex == "#FF0080")
}

@Test func themeRoundTrips() throws {
    var theme = Theme(name: "Mine")
    theme[.background, dark: true] = HexColor(0x101010)
    theme[.keyword, dark: false] = HexColor(0x0000FF, alpha: 0x80)
    theme[.draft, dark: false] = HexColor(0x00FF00)
    #expect(try Theme.decode(theme.encoded()) == theme)
}

@Test func partialThemeFallsBackToBuiltIn() throws {
    let file = """
    {"name": "Partial", "colors": {
        "editor.background": {"dark": "#000000"},
        "syntax.string": {"light": "#112233", "dark": "#445566"},
        "someday.newKey": {"light": "#FFFFFF"}
    }}
    """
    let theme = try Theme.decode(Data(file.utf8))
    #expect(theme.name == "Partial")
    #expect(theme.color(.background, dark: true) == HexColor(0x000000))
    #expect(theme.color(.background, dark: false) == HexColor(0xFFFFFF))
    #expect(theme.color(.string, dark: false) == HexColor(0x112233))
    #expect(theme.color(.keyword, dark: true) == Theme.builtIn[.keyword]?.dark)
    #expect(theme.color(.draft, dark: true) == nil) // follows the system accent

    for file in [#"{"name": "Empty", "colors": {}}"#, #"{"name": "No colors"}"#, "{}"] {
        let empty = try Theme.decode(Data(file.utf8))
        #expect(empty.colors.isEmpty)
        for key in ThemeKey.allCases { #expect(empty.color(key, dark: false) == Theme.default.color(key, dark: false)) }
    }
    #expect(try Theme.decode(Data("{}".utf8)).name == "")
}

@Test func invalidThemeFilesThrow() {
    let bad = [
        ##"{"name": "X", "colors": {"editor.background": {"dark": "#12"}}}"##, // bad hex
        ##"{"name": "X", "colors": {"editor.background": "#123456"}}"##, // wrong shape
        #"{"name": 3}"#, // wrong type
        "not json",
    ]
    for file in bad { #expect(throws: (any Error).self) { try Theme.decode(Data(file.utf8)) } }
}

@Test func clearingBothSidesRemovesTheEntry() {
    var theme = Theme(name: "T")
    theme[.added, dark: true] = HexColor(0x123456)
    theme[.added, dark: true] = nil
    #expect(theme.colors.isEmpty)
}

@Test func everySyntaxKindHasABuiltInColor() {
    for kind in [SyntaxKind.comment, .string, .keyword, .number, .call] {
        #expect(Theme.builtIn[ThemeKey.syntax(kind)] != nil)
    }
}

@Test func resolvedThemeSetsEveryBuiltInColor() throws {
    var theme = Theme(name: "T")
    theme[.added, dark: true] = HexColor(0x123456)
    let resolved = theme.resolved()
    #expect(resolved[.added, dark: true] == HexColor(0x123456))
    #expect(resolved[.added, dark: false] == Theme.builtIn[.added]?.light)
    #expect(resolved[.draft, dark: false] == nil)
    #expect(resolved.colors.count == Theme.builtIn.count)
    #expect(try Theme.decode(resolved.encoded()) == resolved)
}

@Test func invalidThemeErrorsSayWhatIsWrong() {
    func message(_ file: String) -> String? {
        do { _ = try Theme.decode(Data(file.utf8)) } catch { return error.localizedDescription }
        return nil
    }
    #expect(message(##"{"name": "X", "colors": {"editor.text": {"dark": "#12"}}}"##)?.contains("editor.text.dark") == true)
    #expect(message(##"{"name": "X", "colors": {"editor.text": {"dark": "#12"}}}"##)?.contains("isn't a hex color") == true)
    #expect(message(#"{"name": 3}"#)?.hasPrefix("Unexpected value at “name”") == true)
    #expect(message("not json") == "This isn't a JSON file.")
}

@Test func importRefusesFilesTooLargeToBeThemes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(count: Theme.maxFileSize + 1).write(to: url)
    #expect(throws: ThemeFileError("This file is too large to be a theme.")) { try Theme.fileData(url) }
    try Data(#"{"name": "Small"}"#.utf8).write(to: url)
    #expect(try Theme.decode(Theme.fileData(url)).name == "Small")
}

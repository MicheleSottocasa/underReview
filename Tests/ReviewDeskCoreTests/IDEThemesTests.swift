import Foundation
import Testing
@testable import ReviewDeskCore

/// A temporary folder with the given files (path → contents), removed by the caller.
private func folder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ide-themes-\(UUID())")
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return root
}

@Test func jsoncDropsCommentsAndTrailingCommas() throws {
    let text = #"""
    {
        // a comment
        "url": "https://example.com/*not a comment*/", /* block
        comment */ "quote": "say \"hi\" // still text",
        "list": [1, 2, ],
    }
    """#
    let json = try #require(JSONC.object(Data(text.utf8)) as? [String: Any])
    #expect(json["url"] as? String == "https://example.com/*not a comment*/")
    #expect(json["quote"] as? String == #"say "hi" // still text"#)
    #expect(json["list"] as? [Int] == [1, 2])
}

private let vscodeParent = #"""
{
    "name": "Parent",
    "type": "dark",
    "colors": { "editor.background": "#111111", "editor.foreground": "#EEEEEE", "editorLineNumber.foreground": "#555555" },
    "tokenColors": [
        { "settings": { "foreground": "#DDDDDD" } },
        { "scope": "keyword", "settings": { "foreground": "#0000AA" } },
        { "scope": ["string", "string.quoted.double"], "settings": { "foreground": "#00AA00" } },
    ]
}
"""#

private let vscodeChild = #"""
{
    // VS Code themes are JSONC
    "name": "Child",
    "include": "./parent.json",
    "colors": {
        "editor.background": "#1E1E1E",
        "diffEditor.insertedLineBackground": "#9BB95533",
    },
    "tokenColors": [
        { "scope": "keyword.control", "settings": { "foreground": "#FF00FF" } },
        { "scope": "comment, punctuation.definition.comment", "settings": { "foreground": "#6A9955" } },
        { "scope": "entity.name.function", "settings": { "foreground": "#DCDCAA" } },
        { "scope": "constant.numeric", "settings": { "fontStyle": "italic" } },
    ]
}
"""#

@Test func vscodeThemeFollowsIncludeAndMapsColors() throws {
    let root = try folder(["themes/parent.json": vscodeParent, "themes/child.json": vscodeChild])
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = try VSCodeTheme.load(root.appendingPathComponent("themes/child.json"))
    #expect(theme.name == "Child")
    #expect(theme.dark)
    #expect(theme.colors[.background] == HexColor(0x1E1E1E)) // the child wins
    #expect(theme.colors[.text] == HexColor(0xEEEEEE)) // from the parent
    #expect(theme.colors[.lineNumber] == HexColor(0x555555))
    #expect(theme.colors[.added] == HexColor(0x9BB955, alpha: 0x33))
    #expect(theme.colors[.keyword] == HexColor(0x0000AA)) // plain "keyword" before "keyword.control"
    #expect(theme.colors[.string] == HexColor(0x00AA00))
    #expect(theme.colors[.comment] == HexColor(0x6A9955))
    #expect(theme.colors[.call] == HexColor(0xDCDCAA))
    #expect(theme.colors[.number] == nil) // no foreground: falls back
    #expect(theme.colors[.modified] == nil)
}

@Test func textMateMatchingPrefersTheMostSpecificSelector() {
    let rules: [(scopes: [String], foreground: String)] = [
        (["string.quoted"], "#111111"), (["string"], "#222222"), (["string.quoted.double.json"], "#333333"),
    ]
    #expect(VSCodeTheme.foreground(for: "string.quoted", in: rules) == HexColor(0x111111))
    #expect(VSCodeTheme.foreground(for: "string", in: rules) == HexColor(0x222222))
    #expect(VSCodeTheme.foreground(for: "stringy", in: rules) == nil)
}

@Test func vscodeUserSettingsOverrideTheTheme() throws {
    let root = try folder(["child.json": vscodeChild, "parent.json": vscodeParent])
    defer { try? FileManager.default.removeItem(at: root) }
    let settings: [String: Any] = [
        "workbench.colorCustomizations": ["editor.background": "#000000", "[Other]": ["editor.foreground": "#FFFFFF"]],
        "editor.tokenColorCustomizations": [
            "comments": "#123456",
            "[Child]": ["strings": ["foreground": "#654321"], "textMateRules": [["scope": "constant.numeric", "settings": ["foreground": "#ABCDEF"]]]],
        ],
    ]
    let theme = try VSCodeTheme.load(root.appendingPathComponent("child.json"), settings: settings)
    #expect(theme.colors[.background] == HexColor(0x000000))
    #expect(theme.colors[.text] == HexColor(0xEEEEEE)) // the override is for another theme
    #expect(theme.colors[.comment] == HexColor(0x123456))
    #expect(theme.colors[.string] == HexColor(0x654321))
    #expect(theme.colors[.number] == HexColor(0xABCDEF))
}

@Test func detectsVSCodeAndCursorThemes() throws {
    let home = try folder([
        "Library/Application Support/Code/User/settings.json": #"{ "workbench.colorTheme": "Night Owl", }"#,
        ".vscode/extensions/owl/package.json": #"{"contributes": {"themes": [{"label": "%owl%", "uiTheme": "vs-dark", "path": "./themes/owl.json"}]}}"#,
        ".vscode/extensions/owl/package.nls.json": #"{"owl": "Night Owl"}"#,
        ".vscode/extensions/owl/themes/owl.json": ##"{"colors": {"editor.background": "#011627"}}"##,
        "Library/Application Support/Cursor/User/settings.json": #"""
        { "window.autoDetectColorScheme": true, "workbench.preferredLightColorTheme": "Paper" }
        """#,
        "Apps/Cursor.app/Contents/Resources/app/extensions/theme-paper/package.json":
            #"{"contributes": {"themes": [{"id": "Paper", "label": "Paper Light", "uiTheme": "vs", "path": "./paper.json"}]}}"#,
        "Apps/Cursor.app/Contents/Resources/app/extensions/theme-paper/paper.json": ##"{"colors": {"editor.background": "#FAFAFA"}}"##,
    ])
    defer { try? FileManager.default.removeItem(at: home) }
    // The app is only in the second folder, as ~/Applications is after /Applications.
    let sources = VSCodeTheme.installed(home: home, applications: [home.appendingPathComponent("Missing"), home.appendingPathComponent("Apps")])
    #expect(sources.map(\.name) == ["VS Code", "Cursor"])

    #expect(sources[0].themes.map(\.name) == ["Night Owl"])
    #expect(sources[0].themes.first?.dark == true) // from uiTheme, the file has no type
    #expect(sources[0].themes.first?.colors[.background] == HexColor(0x011627))
    #expect(sources[0].problem == nil)

    // Following the system: the preferred light theme is found, the default dark one isn't installed here.
    #expect(sources[1].themes.map(\.name) == ["Paper"])
    #expect(sources[1].themes.first?.dark == false)
    #expect(sources[1].problem == "Couldn't find the theme “Default Dark Modern”.")
}

private let customScheme = """
<scheme name="_@user_Ocean" version="142" parent_scheme="Base">
  <colors>
    <option name="LINE_NUMBERS_COLOR" value="ff" />
  </colors>
  <attributes>
    <option name="DEFAULT_KEYWORD">
      <value><option name="FOREGROUND" value="c792ea" /></value>
    </option>
    <option name="DIFF_INSERTED">
      <value><option name="BACKGROUND" value="1e3a2a" /></value>
    </option>
  </attributes>
</scheme>
"""

private let baseScheme = """
<scheme name="Base" version="142" parent_scheme="Darcula">
  <attributes>
    <option name="TEXT">
      <value><option name="FOREGROUND" value="d6deeb" /><option name="BACKGROUND" value="11" /></value>
    </option>
    <option name="DEFAULT_KEYWORD">
      <value><option name="FOREGROUND" value="aaaaaa" /></value>
    </option>
  </attributes>
</scheme>
"""

@Test func jetBrainsSchemeFollowsParentsDownToAPreset() throws {
    let root = try folder(["colors/_@user_Ocean.icls": customScheme, "colors/Base.icls": baseScheme])
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = try JetBrainsScheme.load(file: root.appendingPathComponent("colors/_@user_Ocean.icls"))
    let darcula = try #require(JetBrainsScheme.presets["Darcula"])
    #expect(theme.name == "Ocean")
    #expect(theme.dark)
    #expect(theme.colors[.lineNumber] == HexColor(0x0000FF)) // leading zeros dropped in the file
    #expect(theme.colors[.keyword] == HexColor(0xC792EA)) // the child wins
    #expect(theme.colors[.text] == HexColor(0xD6DEEB)) // from Base
    #expect(theme.colors[.background] == HexColor(0x000011))
    #expect(theme.colors[.added] == HexColor(0x1E3A2A))
    #expect(theme.colors[.string] == darcula.colors[.string]) // from the Darcula preset
    #expect(theme.note == nil)
}

@Test func jetBrainsPartialSaveOfAnUnreadableSchemeSaysSo() throws {
    let partial = """
    <scheme name="_@user_Tokyo" version="142" parent_scheme="Darcula">
      <metaInfo>
        <property name="originalScheme">Tokyo</property>
        <property name="partialSave">true</property>
      </metaInfo>
      <colors><option name="LINE_NUMBERS_COLOR" value="696969" /></colors>
    </scheme>
    """
    let root = try folder(["colors/_@user_Tokyo.icls": partial])
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = try JetBrainsScheme.load(file: root.appendingPathComponent("colors/_@user_Tokyo.icls"))
    #expect(theme.colors[.lineNumber] == HexColor(0x696969))
    #expect(theme.colors[.keyword] == JetBrainsScheme.presets["Darcula"]?.colors[.keyword])
    #expect(theme.note?.contains("“Tokyo”") == true)
}

@Test func detectsTheNewestJetBrainsIDEAndItsSchemes() throws {
    let home = try folder([
        "Library/Application Support/JetBrains/PyCharm2025.3/options/colors.scheme.xml":
            #"<application><component name="EditorColorsManagerImpl"><global_color_scheme name="Darcula" /></component></application>"#,
        "Library/Application Support/JetBrains/PyCharm2026.1/options/colors.scheme.xml":
            #"<application><component name="EditorColorsManagerImpl"><global_color_scheme name="Ocean" /></component></application>"#,
        "Library/Application Support/JetBrains/PyCharm2026.1/options/laf.xml": """
        <application><component name="LafManager" autodetect="true">
          <laf themeId="ExperimentalDark" />
          <preferred-dark-laf themeId="ExperimentalDark" />
          <lafs-to-previous-schemes><laf-to-scheme laf="ExperimentalLight" scheme="IntelliJ Light" /></lafs-to-previous-schemes>
        </component></application>
        """,
        "Library/Application Support/JetBrains/PyCharm2026.1/colors/_@user_Ocean.icls": customScheme,
        "Library/Application Support/JetBrains/PyCharm2026.1/colors/Base.icls": baseScheme,
        "Library/Application Support/JetBrains/Toolbox/options/other.xml": "<application/>",
        "Library/Application Support/Google/AndroidStudio2025.1/options/colors.scheme.xml":
            #"<application><component name="EditorColorsManagerImpl"><global_color_scheme name="Sunset" /></component></application>"#,
    ])
    defer { try? FileManager.default.removeItem(at: home) }
    let sources = JetBrainsScheme.installed(home: home)
    #expect(sources.map(\.name) == ["AndroidStudio 2025.1", "PyCharm 2026.1"])

    #expect(sources[0].themes.isEmpty)
    #expect(sources[0].problem?.hasPrefix("“Sunset” can't be read") == true)

    // Follows the system: the light scheme last used with the light look, and the current dark one.
    #expect(sources[1].themes.map(\.name) == ["IntelliJ Light", "Ocean"])
    #expect(sources[1].themes.map(\.dark) == [false, true])
}

@Test func importingKeepsTheOtherSide() {
    var base = Theme(name: "Mine")
    base[.background, dark: false] = HexColor(0xFFFFEE)
    base[.background, dark: true] = HexColor(0x222222)
    base[.keyword, dark: true] = HexColor(0x333333)
    let ide = IDETheme(name: "Owl", dark: true, colors: [.background: HexColor(0x011627)])
    let theme = Theme.imported([ide], into: base)
    #expect(theme.name == "Owl")
    #expect(theme[.background, dark: false] == HexColor(0xFFFFEE))
    #expect(theme[.background, dark: true] == HexColor(0x011627))
    #expect(theme[.keyword, dark: true] == nil) // not in the IDE theme: the default, not the old color
}

@Test func importFileRecognizesEachFormat() throws {
    let root = try folder([
        "mine.json": #"{"name": "Mine", "colors": {}}"#,
        "vscode.json": vscodeParent,
        "scheme.icls": baseScheme,
        "broken.json": ##"{"name": "X", "colors": {"editor.text": {"dark": "#12"}}}"##,
        "other.json": #"{"hello": "world"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    #expect(try Theme.importFile(url("mine.json")).theme?.name == "Mine")
    #expect(try Theme.importFile(url("vscode.json")).ide?.name == "Parent")
    #expect(try Theme.importFile(url("scheme.icls")).ide?.name == "Base")
    // A broken ReviewDesk theme reports its own problem, not "not a VS Code theme".
    #expect(throws: ThemeFileError.self) { try Theme.importFile(url("broken.json")) }
    do { _ = try Theme.importFile(url("broken.json")) } catch { #expect(error.localizedDescription.contains("isn't a hex color")) }
    #expect(throws: (any Error).self) { try Theme.importFile(url("other.json")) }
}

@Test func vscodeThemeWithAMissingIncludeKeepsItsOwnColors() throws {
    let file = ##"""
    { "name": "Lonely", "include": "./dark_plus.json", "colors": { "editor.background": "#202020", "editor.foreground": null } }
    """##
    let root = try folder(["lonely.json": file])
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = try #require(Theme.importFile(root.appendingPathComponent("lonely.json")).ide)
    #expect(theme.colors[.background] == HexColor(0x202020)) // a null value doesn't drop the other colors
    #expect(theme.note == "“dark_plus.json” wasn't found or couldn't be read, so only this file's colors were imported.")
}

@Test func includeAndParentCyclesEnd() throws {
    let root = try folder([
        "a.json": ##"{"name": "A", "include": "./b.json", "colors": {"editor.background": "#0A0A0A"}}"##,
        "b.json": ##"{"name": "B", "include": "./a.json", "colors": {"editor.foreground": "#0B0B0B"}}"##,
        "A.icls": #"<scheme name="A" parent_scheme="B"><colors><option name="LINE_NUMBERS_COLOR" value="aaaaaa" /></colors></scheme>"#,
        "B.icls": #"<scheme name="B" parent_scheme="A"><colors><option name="INDENT_GUIDE" value="bbbbbb" /></colors></scheme>"#,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let vscode = try VSCodeTheme.load(root.appendingPathComponent("a.json"))
    #expect(vscode.colors[.background] == HexColor(0x0A0A0A))
    #expect(vscode.colors[.text] == HexColor(0x0B0B0B))
    let jetbrains = try JetBrainsScheme.load(file: root.appendingPathComponent("A.icls"))
    #expect(jetbrains.colors[.lineNumber] == HexColor(0xAAAAAA))
    #expect(jetbrains.colors[.separator] == HexColor(0xBBBBBB))
}

@Test func includeOfANonRegularFileIsSkipped() throws {
    let root = try folder(["t.json": ##"{"name": "T", "include": "../../../../../../../../../../dev/zero", "colors": {"editor.background": "#101010"}}"##])
    defer { try? FileManager.default.removeItem(at: root) }
    let theme = try VSCodeTheme.load(root.appendingPathComponent("t.json"))
    #expect(theme.colors[.background] == HexColor(0x101010))
    #expect(theme.note?.contains("“zero”") == true)
}

@Test func followingTheSystemWithTwoDarkThemesKeepsOne() throws {
    let home = try folder([
        "Library/Application Support/Code/User/settings.json": """
        { "window.autoDetectColorScheme": true, "workbench.preferredLightColorTheme": "Owl", "workbench.preferredDarkColorTheme": "Night" }
        """,
        ".vscode/extensions/t/package.json": #"""
        {"contributes": {"themes": [{"label": "Owl", "uiTheme": "vs-dark", "path": "./owl.json"}, {"label": "Night", "uiTheme": "vs-dark", "path": "./night.json"}]}}
        """#,
        ".vscode/extensions/t/owl.json": ##"{"colors": {"editor.background": "#011627"}}"##,
        ".vscode/extensions/t/night.json": ##"{"colors": {"editor.background": "#000000"}}"##,
    ])
    defer { try? FileManager.default.removeItem(at: home) }
    let source = try #require(VSCodeTheme.installed(home: home, applications: []).first)
    #expect(source.themes.map(\.name) == ["Night"]) // the dark slot's theme
}

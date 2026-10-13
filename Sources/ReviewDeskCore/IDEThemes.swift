import Foundation

/// A color theme read from an IDE: one appearance (light or dark) and only the colors the IDE defines.
public struct IDETheme: Equatable, Sendable {
    public var name: String
    public var dark: Bool
    public var colors: [ThemeKey: HexColor]
    /// Set when part of the theme couldn't be read.
    public var note: String?

    public init(name: String, dark: Bool, colors: [ThemeKey: HexColor], note: String? = nil) {
        (self.name, self.dark, self.colors, self.note) = (name, dark, colors, note)
    }
}

/// An installed IDE and its current theme: one, or a light and a dark one when it follows the system.
public struct IDESource: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var themes: [IDETheme]
    /// Why no theme could be read.
    public var problem: String?
}

extension Theme {
    /// `base` with the IDE themes' sides replaced: what an IDE defines, else the default. The other side keeps `base`.
    public static func imported(_ themes: [IDETheme], into base: Theme) -> Theme {
        var theme = Theme(name: themes.map(\.name).joined(separator: " / "), colors: base.colors)
        for ide in themes {
            for key in ThemeKey.allCases { theme[key, dark: ide.dark] = ide.colors[key] }
        }
        return theme
    }

    /// Reads a theme file for Import…: a ReviewDesk theme, a VS Code theme or a JetBrains `.icls` scheme.
    /// The second value is set for IDE files, which are reviewed before they're saved.
    public static func importFile(_ url: URL) throws -> (theme: Theme?, ide: IDETheme?) {
        if url.pathExtension.lowercased() == "icls" { return (nil, try JetBrainsScheme.load(file: url)) }
        if let vscode = try? VSCodeTheme.load(url) { return (nil, vscode) }
        let theme = try decode(fileData(url))
        guard !theme.name.isEmpty || !theme.colors.isEmpty else { throw ThemeFileError(notATheme) }
        return (theme, nil)
    }

    static let notATheme = "This isn't a ReviewDesk, VS Code or JetBrains theme."
}

// MARK: - JSONC

/// JSON with comments and trailing commas, as VS Code writes settings and themes.
public enum JSONC {
    public static func object(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(strip(Array(data))), options: .fragmentsAllowed)
    }

    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\")
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i], next = i + 1 < bytes.count ? bytes[i + 1] : 0
            if c == quote {
                out.append(c)
                i += 1
                while i < bytes.count {
                    let d = bytes[i]
                    out.append(d)
                    i += 1
                    if d == backslash, i < bytes.count { out.append(bytes[i]); i += 1 } else if d == quote { break }
                }
            } else if c == slash, next == slash {
                while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
            } else if c == slash, next == star {
                i += 2
                while i < bytes.count, !(bytes[i] == star && i + 1 < bytes.count && bytes[i + 1] == slash) { i += 1 }
                i += 2
            } else {
                if c == UInt8(ascii: "}") || c == UInt8(ascii: "]"),
                   let last = out.lastIndex(where: { !($0 == 32 || $0 == 9 || $0 == 10 || $0 == 13) }), out[last] == UInt8(ascii: ",") {
                    out.remove(at: last)
                }
                out.append(c)
                i += 1
            }
        }
        return out
    }
}

// MARK: - VS Code and Cursor

public enum VSCodeTheme {
    /// Reads a theme file and the files it `include`s. Throws when it isn't a VS Code theme.
    /// `dark` is the editor's own say (`uiTheme` in the extension), used when the file has no `type`.
    public static func load(_ url: URL, settings: [String: Any] = [:], dark: Bool? = nil) throws -> IDETheme {
        var raw = Raw()
        try raw.read(url, depth: 0)
        guard raw.isTheme else { throw ThemeFileError(Theme.notATheme) }
        let name = raw.name ?? url.deletingPathExtension().lastPathComponent
        return theme(name: name, raw: raw, settings: settings, dark: dark)
    }

    struct Raw {
        var name: String?
        var type: String?
        var colors: [String: String] = [:]
        var rules: [(scopes: [String], foreground: String)] = []
        var isTheme = false
        /// An `include` that couldn't be read: the theme is imported without it.
        var missingInclude: String?

        mutating func read(_ url: URL, depth: Int) throws {
            guard depth < 10 else { return }
            guard let json = try JSONC.object(Theme.fileData(url)) as? [String: Any] else { return }
            if let include = json["include"] as? String {
                do {
                    try read(url.deletingLastPathComponent().appendingPathComponent(include), depth: depth + 1)
                } catch {
                    missingInclude = missingInclude ?? (include as NSString).lastPathComponent
                }
                isTheme = true
            }
            if depth == 0 { name = json["name"] as? String }
            type = json["type"] as? String ?? type
            if let colors = (json["colors"] as? [String: Any])?.compactMapValues({ $0 as? String }), !colors.isEmpty {
                self.colors.merge(colors) { $1 }
                isTheme = true
            }
            if let tokenColors = json["tokenColors"] as? [[String: Any]] {
                rules += Self.rules(tokenColors)
                isTheme = true
            }
        }

        static func rules(_ list: [[String: Any]]) -> [(scopes: [String], foreground: String)] {
            list.compactMap { rule in
                guard let settings = rule["settings"] as? [String: Any], let foreground = settings["foreground"] as? String else { return nil }
                let scopes: [String] = switch rule["scope"] {
                case let text as String: text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case let list as [String]: list
                default: [""] // no scope: the editor's default text color
                }
                return (scopes, foreground)
            }
        }
    }

    private static let colorKeys: [(ThemeKey, [String])] = [
        (.background, ["editor.background"]),
        (.text, ["editor.foreground"]),
        (.lineNumber, ["editorLineNumber.foreground"]),
        (.separator, ["editorIndentGuide.background1", "editorIndentGuide.background", "editorGroup.border"]),
        (.fold, ["diffEditor.unchangedRegionBackground", "editor.foldBackground"]),
        (.added, ["diffEditor.insertedLineBackground", "diffEditor.insertedTextBackground"]),
        (.removed, ["diffEditor.removedLineBackground", "diffEditor.removedTextBackground"]),
    ]

    /// TextMate scopes tried in order for each syntax kind; the first one a rule matches wins.
    private static let scopes: [(ThemeKey, [String])] = [
        (.keyword, ["keyword", "keyword.control", "storage.type"]),
        (.string, ["string", "string.quoted"]),
        (.comment, ["comment", "comment.line"]),
        (.number, ["constant.numeric"]),
        (.call, ["entity.name.function", "support.function", "meta.function-call"]),
    ]

    /// `editor.tokenColorCustomizations` shortcuts.
    private static let shortcuts: [(String, ThemeKey)] = [
        ("keywords", .keyword), ("strings", .string), ("comments", .comment), ("numbers", .number), ("functions", .call),
    ]

    static func theme(name: String, raw: Raw, settings: [String: Any], dark: Bool? = nil) -> IDETheme {
        var raw = raw
        // User settings: the general ones, then those for this theme only ("[Theme Name]").
        var shortcutColors: [ThemeKey: String] = [:]
        for overrides in [settings["workbench.colorCustomizations"], settings["editor.tokenColorCustomizations"]] {
            guard let overrides = overrides as? [String: Any] else { continue }
            for scope in [overrides, overrides["[\(name)]"] as? [String: Any] ?? [:]] {
                raw.colors.merge(scope.compactMapValues { $0 as? String }.filter { $0.key.contains(".") }) { $1 }
                if let rules = scope["textMateRules"] as? [[String: Any]] { raw.rules += Raw.rules(rules) }
                for (shortcut, key) in shortcuts {
                    switch scope[shortcut] {
                    case let color as String: shortcutColors[key] = color
                    case let style as [String: Any]: if let color = style["foreground"] as? String { shortcutColors[key] = color }
                    default: break
                    }
                }
            }
        }
        var colors: [ThemeKey: HexColor] = [:]
        for (key, names) in colorKeys {
            colors[key] = names.lazy.compactMap { raw.colors[$0].flatMap(HexColor.init(hex:)) }.first
        }
        if colors[.text] == nil { colors[.text] = foreground(for: "", in: raw.rules) }
        for (key, targets) in scopes {
            colors[key] = targets.lazy.compactMap { foreground(for: $0, in: raw.rules) }.first
        }
        for (key, color) in shortcutColors { colors[key] = HexColor(hex: color) ?? colors[key] }
        let isDark: Bool = switch raw.type {
        case "light", "hcLight": false
        case "dark", "hc", "hcDark": true
        default: dark ?? colors[.background].map { luminance($0) < 0.5 } ?? true
        }
        let note = raw.missingInclude.map { "“\($0)” wasn't found or couldn't be read, so only this file's colors were imported." }
        return IDETheme(name: name, dark: isDark, colors: colors, note: note)
    }

    /// TextMate matching, simplified: a selector matches a scope it's a dot-prefix of; the longest selector wins,
    /// and the later rule among equals. Descendant selectors ("a b") are skipped.
    static func foreground(for target: String, in rules: [(scopes: [String], foreground: String)]) -> HexColor? {
        var best: (score: Int, color: HexColor)?
        for rule in rules {
            for selector in rule.scopes where !selector.contains(" ") {
                guard selector == target || (!selector.isEmpty && target.hasPrefix(selector + ".")),
                      let color = HexColor(hex: rule.foreground) else { continue }
                let score = selector.isEmpty ? 0 : selector.split(separator: ".").count
                if score >= best?.score ?? 0 { best = (score, color) }
            }
        }
        return best?.color
    }

    static func luminance(_ color: HexColor) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    // MARK: Installed editors

    struct Flavor {
        var name: String
        var support: String
        var extensions: String
        var app: String
        var defaultTheme: String
    }

    static let flavors = [
        Flavor(name: "VS Code", support: "Code", extensions: ".vscode/extensions", app: "Visual Studio Code.app", defaultTheme: "Default Dark Modern"),
        Flavor(name: "Cursor", support: "Cursor", extensions: ".cursor/extensions", app: "Cursor.app", defaultTheme: "Cursor Dark"),
    ]

    static func installed(home: URL, applications: [URL]) -> [IDESource] {
        let files = FileManager.default
        return flavors.compactMap { flavor in
            let user = home.appendingPathComponent("Library/Application Support/\(flavor.support)/User")
            let app = applications.map { $0.appendingPathComponent(flavor.app) }.first { files.fileExists(atPath: $0.path) }
            guard files.fileExists(atPath: user.path) || app != nil else { return nil }
            let settings = (try? Theme.fileData(user.appendingPathComponent("settings.json")))
                .flatMap { try? JSONC.object($0) as? [String: Any] } ?? [:]
            let names = settings["window.autoDetectColorScheme"] as? Bool == true
                ? [settings["workbench.preferredLightColorTheme"] as? String ?? "Default Light Modern",
                   settings["workbench.preferredDarkColorTheme"] as? String ?? "Default Dark Modern"]
                : [settings["workbench.colorTheme"] as? String ?? flavor.defaultTheme]
            let folders = [home.appendingPathComponent(flavor.extensions)] + (app.map { [$0.appendingPathComponent("Contents/Resources/app/extensions")] } ?? [])
            let contributed = themeFiles(in: folders)
            var themes: [IDETheme] = [], missing: [String] = []
            for name in names {
                if let file = contributed[name], var theme = try? load(file.url, settings: settings, dark: file.dark) {
                    theme.name = name
                    themes.append(theme)
                } else {
                    missing.append(name)
                }
            }
            let problem = missing.isEmpty ? nil : "Couldn't find the theme \(missing.map { "“\($0)”" }.joined(separator: " and "))."
            return IDESource(id: user.path, name: flavor.name, themes: oneThemePerAppearance(themes), problem: problem)
        }
    }

    /// Every theme contributed by an extension in these folders (`contributes.themes` in its `package.json`),
    /// by id and by label.
    static func themeFiles(in folders: [URL]) -> [String: (url: URL, dark: Bool)] {
        var result: [String: (url: URL, dark: Bool)] = [:]
        for folder in folders {
            for extensionURL in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let data = try? Theme.fileData(extensionURL.appendingPathComponent("package.json")),
                      let package = try? JSONC.object(data) as? [String: Any],
                      let themes = (package["contributes"] as? [String: Any])?["themes"] as? [[String: Any]] else { continue }
                let strings = (try? Theme.fileData(extensionURL.appendingPathComponent("package.nls.json")))
                    .flatMap { try? JSONC.object($0) as? [String: Any] } ?? [:]
                for theme in themes {
                    guard let path = theme["path"] as? String else { continue }
                    let entry = (extensionURL.appendingPathComponent(path).standardizedFileURL, !["vs", "hc-light"].contains(theme["uiTheme"] as? String ?? ""))
                    var label = theme["label"] as? String
                    if let key = label, key.hasPrefix("%"), key.hasSuffix("%") { label = strings[String(key.dropFirst().dropLast())] as? String }
                    for name in [theme["id"] as? String, label].compactMap({ $0 }) where result[name] == nil { result[name] = entry }
                }
            }
        }
        return result
    }
}

// MARK: - JetBrains

public enum JetBrainsScheme {
    /// Reads an `.icls` scheme. Its `parent_scheme` is looked up next to it, then among the bundled presets.
    public static func load(file: URL) throws -> IDETheme {
        try resolve(Scheme(Theme.fileData(file)), folder: file.deletingLastPathComponent())
    }

    struct Scheme {
        var name: String
        var parent: String?
        /// The scheme a partial save only changes (`metaInfo` › `originalScheme`).
        var original: String?
        var colors: [ThemeKey: HexColor] = [:]

        init(_ data: Data) throws {
            let document: XMLDocument
            do { document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) } catch { throw ThemeFileError("This isn't a JetBrains color scheme.") }
            guard let root = document.rootElement(), root.name == "scheme", let name = root.attribute(forName: "name")?.stringValue else {
                throw ThemeFileError("This isn't a JetBrains color scheme.")
            }
            self.name = name
            parent = root.attribute(forName: "parent_scheme")?.stringValue
            let meta = root.elements(forName: "metaInfo").first?.elements(forName: "property") ?? []
            if meta.contains(where: { $0.attribute(forName: "name")?.stringValue == "partialSave" && $0.stringValue == "true" }) {
                original = meta.first { $0.attribute(forName: "name")?.stringValue == "originalScheme" }?.stringValue
            }
            func options(_ element: XMLElement?) -> [String: XMLElement] {
                Dictionary((element?.elements(forName: "option") ?? []).compactMap { option in
                    option.attribute(forName: "name")?.stringValue.map { ($0, option) }
                }) { _, last in last }
            }
            func color(_ option: XMLElement?) -> HexColor? {
                option?.attribute(forName: "value")?.stringValue.flatMap(JetBrainsScheme.color)
            }
            let plain = options(root.elements(forName: "colors").first)
            let attributes = options(root.elements(forName: "attributes").first)
            func attribute(_ name: String, _ part: String) -> HexColor? {
                color(options(attributes[name]?.elements(forName: "value").first)[part])
            }
            colors[.background] = attribute("TEXT", "BACKGROUND")
            colors[.text] = attribute("TEXT", "FOREGROUND")
            colors[.lineNumber] = color(plain["LINE_NUMBERS_COLOR"])
            colors[.separator] = color(plain["INDENT_GUIDE"])
            colors[.fold] = color(plain["DIFF_SEPARATORS_BACKGROUND"]) ?? attribute("FOLDED_TEXT_ATTRIBUTES", "BACKGROUND")
            colors[.added] = attribute("DIFF_INSERTED", "BACKGROUND")
            colors[.modified] = attribute("DIFF_MODIFIED", "BACKGROUND")
            colors[.removed] = attribute("DIFF_DELETED", "BACKGROUND")
            colors[.keyword] = attribute("DEFAULT_KEYWORD", "FOREGROUND")
            colors[.string] = attribute("DEFAULT_STRING", "FOREGROUND")
            colors[.comment] = attribute("DEFAULT_LINE_COMMENT", "FOREGROUND")
            colors[.number] = attribute("DEFAULT_NUMBER", "FOREGROUND")
            colors[.call] = attribute("DEFAULT_FUNCTION_CALL", "FOREGROUND")
        }
    }

    /// JetBrains writes colors as hex without `#` and drops leading zeros (`ff` is #0000FF).
    static func color(_ value: String) -> HexColor? {
        guard (1...8).contains(value.count), value.allSatisfy(\.isHexDigit), let number = UInt32(value, radix: 16) else { return nil }
        return value.count > 6 ? HexColor(hex: String(repeating: "0", count: 8 - value.count) + value) : HexColor(number)
    }

    /// The scheme named `name` in `folder`, found by file name as JetBrains saves them (`<name>.icls`, or
    /// `_@user_<name>.icls` for a changed copy). Only the files of the chain are read, never the whole folder.
    static func scheme(named name: String, in folder: URL) -> Scheme? {
        guard !name.contains("/") else { return nil }
        for file in [name, userPrefix + name] {
            if let data = try? Theme.fileData(folder.appendingPathComponent(file + ".icls")), let scheme = try? Scheme(data) {
                return scheme
            }
        }
        return nil
    }

    /// The scheme over its parents: a partial save's original scheme, else its `parent_scheme`, down to a bundled preset.
    static func resolve(_ scheme: Scheme, folder: URL) -> IDETheme {
        var chain = [scheme], note: String?, base: IDETheme?
        var next = scheme.original ?? scheme.parent
        while let name = next, chain.count < 10 {
            if let preset = presets[name] {
                base = preset
                break
            }
            if let parent = self.scheme(named: name, in: folder), !chain.contains(where: { $0.name == parent.name }) {
                chain.append(parent)
                next = parent.original ?? parent.parent
                continue
            }
            // A partial save of a scheme inside the IDE or a plugin: its own changes over the declared parent.
            note = "“\(displayName(name))” is inside the IDE or a plugin and can't be read, so only the changes saved on top of it were imported."
            base = chain.last?.parent.flatMap { presets[$0] }
            break
        }
        var colors = base?.colors ?? [:]
        for scheme in chain.reversed() { colors.merge(scheme.colors) { $1 } }
        let dark = base?.dark ?? colors[.background].map { VSCodeTheme.luminance($0) < 0.5 } ?? true
        return IDETheme(name: displayName(scheme.name), dark: dark, colors: colors, note: note)
    }

    static let userPrefix = "_@user_"

    static func displayName(_ name: String) -> String {
        name.hasPrefix(userPrefix) ? String(name.dropFirst(userPrefix.count)) : name
    }

    /// The schemes bundled inside the IDEs' jars, which can't be read. Dark and Light are the New UI schemes,
    /// ReviewDesk's own defaults.
    // ponytail: Darcula, IntelliJ Light and Classic Light are transcribed from the bundled schemes, not read; update
    // them if JetBrains changes those schemes.
    public static let presets: [String: IDETheme] = {
        func builtIn(dark: Bool) -> [ThemeKey: HexColor] {
            Dictionary(uniqueKeysWithValues: ThemeKey.allCases.compactMap { key in
                Theme.builtIn[key]?[dark: dark].map { (key, $0) }
            }.filter { ![.keyArea, .draft, .outdated, .mine, .others].contains($0.0) })
        }
        func scheme(_ name: String, dark: Bool, _ values: [ThemeKey: UInt32]) -> IDETheme {
            IDETheme(name: name, dark: dark, colors: values.mapValues { HexColor($0) })
        }
        let darcula = scheme("Darcula", dark: true, [
            .background: 0x2B2B2B, .text: 0xA9B7C6, .lineNumber: 0x606366, .separator: 0x373737, .fold: 0x313335,
            .added: 0x294436, .modified: 0x385570, .removed: 0x484A4A,
            .keyword: 0xCC7832, .string: 0x6A8759, .comment: 0x808080, .number: 0x6897BB, .call: 0xA9B7C6,
        ])
        let intellijLight = scheme("IntelliJ Light", dark: false, [
            .background: 0xFFFFFF, .text: 0x080808, .lineNumber: 0xADADAD, .separator: 0xE6E6E6, .fold: 0xF2F2F2,
            .added: 0xBEE6BE, .modified: 0xC2D8F2, .removed: 0xD6D6D6,
            .keyword: 0x0033B3, .string: 0x067D17, .comment: 0x8C8C8C, .number: 0x1750EB, .call: 0x00627A,
        ])
        let classicLight = scheme("Classic Light", dark: false, [
            .background: 0xFFFFFF, .text: 0x000000, .lineNumber: 0x999999, .separator: 0xE6E6E6, .fold: 0xF2F2F2,
            .added: 0xBAEEBA, .modified: 0xBCCFF9, .removed: 0xD6D6D6,
            .keyword: 0x000080, .string: 0x008000, .comment: 0x808080, .number: 0x0000FF, .call: 0x000000,
        ])
        return [
            "Darcula": darcula,
            "IntelliJ Light": intellijLight,
            "Default": classicLight,
            "Dark": IDETheme(name: "Dark", dark: true, colors: builtIn(dark: true)),
            "Light": IDETheme(name: "Light", dark: false, colors: builtIn(dark: false)),
        ]
    }()

    // MARK: Installed IDEs

    /// The newest settings folder of each JetBrains IDE (and Android Studio), with its current scheme.
    static func installed(home: URL) -> [IDESource] {
        let support = home.appendingPathComponent("Library/Application Support")
        var newest: [String: (version: [Int], url: URL)] = [:]
        for vendor in ["JetBrains", "Google"] {
            for folder in (try? FileManager.default.contentsOfDirectory(at: support.appendingPathComponent(vendor), includingPropertiesForKeys: nil)) ?? [] {
                let name = folder.lastPathComponent
                guard let match = name.firstMatch(of: /^([A-Za-z]+)(\d{4})\.(\d+)$/.asciiOnlyDigits()),
                      let year = Int(match.2), let minor = Int(match.3),
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("options").path) else { continue }
                let product = String(match.1), version = [year, minor]
                if newest[product].map({ $0.version.lexicographicallyPrecedes(version) }) ?? true { newest[product] = (version, folder) }
            }
        }
        return newest.sorted { $0.key < $1.key }.map { product, entry in
            let name = (product == "IntelliJIdea" ? "IntelliJ IDEA" : product) + " " + entry.version.map(String.init).joined(separator: ".")
            let names = currentSchemes(entry.url.appendingPathComponent("options"))
            let colors = entry.url.appendingPathComponent("colors")
            var themes: [IDETheme] = [], missing: [String] = []
            for name in names {
                if let scheme = scheme(named: name, in: colors) {
                    themes.append(resolve(scheme, folder: colors))
                } else if let preset = presets[displayName(name)] {
                    themes.append(preset)
                } else {
                    missing.append(name)
                }
            }
            let problem = missing.isEmpty ? nil
                : "“\(missing.map(displayName).joined(separator: "” and “"))” can't be read: it's inside the IDE or a plugin. Choose it in the IDE, then export or duplicate it to read it here."
            return IDESource(id: entry.url.path, name: name, themes: oneThemePerAppearance(themes), problem: problem)
        }
    }

    /// The scheme in use; when the IDE follows the system appearance, the light and the dark one.
    static func currentSchemes(_ options: URL) -> [String] {
        // Documents, not their root elements: an element whose document is freed finds nothing.
        func document(_ file: String) -> XMLDocument? {
            (try? Theme.fileData(options.appendingPathComponent(file))).flatMap {
                try? XMLDocument(data: $0, options: [.nodeLoadExternalEntitiesNever])
            }
        }
        func first(_ node: XMLNode?, _ path: String) -> XMLElement? {
            (try? node?.nodes(forXPath: path))?.first as? XMLElement
        }
        let lafFile = document("laf.xml")
        let current = first(document("colors.scheme.xml"), "//global_color_scheme")?.attribute(forName: "name")?.stringValue ?? "Dark"
        let laf = first(lafFile, "//component[@name='LafManager']")
        guard laf?.attribute(forName: "autodetect")?.stringValue == "true" else { return [current] }
        let currentLaf = first(laf, "laf")?.attribute(forName: "themeId")?.stringValue
        var previous: [String: String] = [:]
        for case let entry as XMLElement in (try? laf?.nodes(forXPath: "lafs-to-previous-schemes/laf-to-scheme")) ?? [] {
            if let key = entry.attribute(forName: "laf")?.stringValue { previous[key] = entry.attribute(forName: "scheme")?.stringValue }
        }
        func scheme(_ tag: String, defaultLaf: String, defaultScheme: String) -> String {
            let id = first(laf, tag)?.attribute(forName: "themeId")?.stringValue ?? defaultLaf
            return id == currentLaf ? current : previous[id] ?? defaultScheme
        }
        let schemes = [scheme("preferred-light-laf", defaultLaf: "ExperimentalLight", defaultScheme: "Light"),
                       scheme("preferred-dark-laf", defaultLaf: "ExperimentalDark", defaultScheme: "Dark")]
        return schemes[0] == schemes[1] ? [current] : schemes
    }
}

// MARK: - Detection

public enum IDEThemes {
    /// Every installed VS Code, Cursor and JetBrains IDE with its current theme. Reads files only.
    /// Apps are looked for in /Applications and ~/Applications.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [IDESource] {
        let applications = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        return VSCodeTheme.installed(home: home, applications: applications) + JetBrainsScheme.installed(home: home)
    }
}

/// A light and a dark theme, in that order, from an IDE following the system. When both turn out to have the same
/// appearance (a dark theme picked as the light one), only the one in its own slot is kept.
func oneThemePerAppearance(_ themes: [IDETheme]) -> [IDETheme] {
    guard themes.count == 2, themes[0].dark == themes[1].dark else { return themes }
    return [themes[0].dark ? themes[1] : themes[0]]
}

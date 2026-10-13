import AppKit
import ReviewDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// The saved color themes and the active one. Themes live in `themes/<id>.json` with the other app files;
/// the active one's id is in the `theme` default ("" is the built-in Default).
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()

    /// id → theme, for every theme file that reads.
    private(set) var saved: [String: Theme] = [:]
    var selectedID: String {
        didSet {
            if !Screenshots.isRequested { UserDefaults.standard.set(selectedID, forKey: "theme") }
            apply()
        }
    }
    private(set) var current = Theme.default
    /// Colors to draw with; the draft accent is missing while it follows the system accent.
    private(set) var palette: [ThemeKey: Color] = [:]

    /// The colors highlighted diff text is drawn with (text and syntax, light and dark).
    var ink: [HexColor?] {
        ([ThemeKey.text, .keyword, .string, .comment, .number, .call]).flatMap { [current.color($0, dark: false), current.color($0, dark: true)] }
    }

    private init() {
        // A screenshot run shows the Default theme and never reads or writes the user's themes.
        selectedID = Screenshots.isRequested ? "" : UserDefaults.standard.string(forKey: "theme") ?? ""
        if !Screenshots.isRequested,
           let files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let theme = try? Theme.decode(data) {
                    saved[file.deletingPathExtension().lastPathComponent] = theme
                }
            }
        }
        if saved[selectedID] == nil { selectedID = "" } // its file is gone or no longer reads
        apply()
    }

    private static let folder = JSONFile<Theme>.appSupport("themes").url

    var sortedIDs: [String] {
        saved.keys.sorted { saved[$0]!.name.localizedStandardCompare(saved[$1]!.name) == .orderedAscending }
    }

    /// Changes the active theme. Default itself never changes: the first edit saves a copy named "Custom".
    func edit(_ change: (inout Theme) -> Void) {
        if saved[selectedID] == nil {
            var copy = Theme.default
            copy.name = uniqueName("Custom")
            change(&copy)
            add(copy)
        } else {
            change(&saved[selectedID]!)
            write(selectedID)
            apply()
        }
    }

    /// Reads a theme file. A ReviewDesk theme becomes the active theme; a VS Code or JetBrains one is returned,
    /// to review before `importIDE` saves it. An invalid file throws and changes nothing.
    func importTheme(from url: URL) throws -> IDETheme? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try Theme.importFile(url)
        guard var theme = file.theme else { return file.ide }
        let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
        theme.name = uniqueName(name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
        add(theme)
        return nil
    }

    /// Saves IDE themes over the active theme's other side, and makes the result the active theme.
    func importIDE(_ themes: [IDETheme]) {
        var theme = Theme.imported(themes, into: current)
        theme.name = uniqueName(theme.name)
        add(theme)
    }

    func delete(_ id: String) {
        saved[id] = nil
        if !Screenshots.isRequested { try? FileManager.default.removeItem(at: JSONFile<Theme>.appSupport("themes/\(id).json").url) }
        if selectedID == id { selectedID = "" }
    }

    private func add(_ theme: Theme) {
        let id = UUID().uuidString
        saved[id] = theme
        write(id)
        selectedID = id
    }

    private func write(_ id: String) {
        guard !Screenshots.isRequested, let theme = saved[id] else { return }
        try? JSONFile<Theme>.appSupport("themes/\(id).json").save(theme)
    }

    private func uniqueName(_ name: String) -> String {
        let names = Set(saved.values.map(\.name) + [Theme.default.name])
        guard names.contains(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !names.contains($0) }!
    }

    private func apply() {
        current = saved[selectedID] ?? .default
        palette = ReviewDesk.palette(current)
    }
}

/// A theme's colors, adapting to light and dark; the draft accent is missing while it follows the system accent.
func palette(_ theme: Theme) -> [ThemeKey: Color] {
    var palette: [ThemeKey: Color] = [:]
    for key in ThemeKey.allCases {
        let light = theme.color(key, dark: false), dark = theme.color(key, dark: true)
        if light != nil || dark != nil { palette[key] = dynamicColor(light: light, dark: dark) }
    }
    return palette
}

/// Built outside the main actor: AppKit calls the provider wherever it resolves the color.
private func dynamicColor(light: HexColor?, dark: HexColor?) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return hex.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? .controlAccentColor
    })
}

/// The diff palette from the active theme (by default PyCharm's New UI colors), adapting to light and dark.
/// Reading a color from a view's body redraws that view when the theme changes.
@MainActor
enum DiffColors {
    private static func color(_ key: ThemeKey) -> Color { ThemeStore.shared.palette[key] ?? .accentColor }

    static var editor: Color { color(.background) }
    static var text: Color { color(.text) }
    static var lineNumber: Color { color(.lineNumber) }
    static var separator: Color { color(.separator) }
    static var fold: Color { color(.fold) }
    static var modified: Color { color(.modified) }
    static var added: Color { color(.added) }
    static var removed: Color { color(.removed) }
    /// The bar beside lines in the AI's key areas.
    static var keyArea: Color { color(.keyArea) }
    /// Drafts and the comment composer; the system accent unless the theme sets one.
    static var draft: Color { color(.draft) }
    /// Drafts outdated by a push.
    static var outdated: Color { color(.outdated) }
    /// Review threads and comments by me, and threads started by others.
    static var mine: Color { color(.mine) }
    static var others: Color { color(.others) }

    enum Side { case left, right }

    static func block(_ change: DiffChange?, side: Side) -> Color {
        switch change {
        case .modified: modified
        case .added: added
        case .removed: removed
        case nil: .clear
        }
    }

    /// The empty side of an added or removed block: a faint version of the block color.
    static func filler(_ change: DiffChange?) -> Color {
        block(change, side: .left).opacity(0.45)
    }

    static func syntax(_ kind: SyntaxKind) -> Color { color(.syntax(kind)) }
}

// MARK: - Settings

struct AppearanceSettings: View {
    @ViewState private var importing = false
    @ViewState private var exporting = false
    @ViewState private var failure: (title: String, message: String)?
    @ViewState private var confirmingDelete = false
    @ViewState private var ideImport: IDEImport?
    private var store: ThemeStore { .shared }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Theme", selection: $store.selectedID) {
                    Text(Theme.default.name).tag("")
                    ForEach(store.sortedIDs, id: \.self) { Text(store.saved[$0]?.name ?? $0).tag($0) }
                }
                if store.saved[store.selectedID] != nil {
                    TextField("Name", text: Binding(get: { store.current.name }, set: { name in store.edit { $0.name = name } }))
                }
                HStack {
                    Button("Import…") { importing = true }
                    Button("Import from IDE…") { ideImport = IDEImport(file: nil) }
                    Button("Export…") { exporting = true }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(store.saved[store.selectedID] == nil)
                    Button("Reset") { store.selectedID = "" }
                        .disabled(store.selectedID.isEmpty)
                        .help("Use the default colors again. Saved themes stay in the menu.")
                }
                HStack(spacing: 12) {
                    ThemePreview(theme: store.current).environment(\.colorScheme, .light)
                    ThemePreview(theme: store.current).environment(\.colorScheme, .dark)
                }
            } header: {
                Text("Color theme")
            } footer: {
                Text("Changing a color of the Default theme saves a copy named Custom. Import… reads ReviewDesk theme files (JSON with a light and a dark hex value per color), VS Code and Cursor theme files and JetBrains .icls schemes; colors a file leaves out use the default.")
            }
            colors("Editor", [.background, .text, .lineNumber, .separator, .fold])
            colors("Diff", [.modified, .added, .removed])
            colors("Accents", [.keyArea, .draft, .outdated, .mine, .others])
            colors("Syntax", [.keyword, .string, .comment, .number, .call])
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "icls", conformingTo: .xml) ?? .xml]) { result in
            do {
                if let ide = try store.importTheme(from: result.get()) { ideImport = IDEImport(file: ide) }
            } catch {
                failure = ("Couldn't import the theme", error.localizedDescription)
            }
        }
        .fileExporter(isPresented: $exporting, document: ThemeDocument(theme: store.current.resolved()),
                      contentType: .json, defaultFilename: store.current.name) { result in
            if case .failure(let error) = result { failure = ("Couldn't export the theme", error.localizedDescription) }
        }
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
        .sheet(item: $ideImport) { IDEImportSheet(file: $0.file) }
        .confirmationDialog("Delete the theme “\(store.current.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { store.delete(store.selectedID) }
        } message: {
            Text("Its file is removed from ReviewDesk. Export it first to keep a copy.")
        }
    }

    private func colors(_ title: String, _ keys: [ThemeKey]) -> some View {
        Section {
            ForEach(keys, id: \.self) { key in
                LabeledContent(Self.title(key)) {
                    HStack(spacing: 16) {
                        well(key, dark: false)
                        well(key, dark: true)
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text("Light").frame(width: 44)
                Text("Dark").frame(width: 44)
            }
        }
    }

    private func well(_ key: ThemeKey, dark: Bool) -> some View {
        let selection = Binding<Color> {
            store.current.color(key, dark: dark).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha) } ?? .accentColor
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let hex = HexColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
            store.edit { $0[key, dark: dark] = hex }
        }
        return ColorPicker("", selection: selection, supportsOpacity: true).labelsHidden().frame(width: 44)
    }

    static func title(_ key: ThemeKey) -> String {
        switch key {
        case .background: "Background"
        case .text: "Text"
        case .lineNumber: "Line numbers"
        case .separator: "Separator"
        case .fold: "Folded lines"
        case .modified: "Modified"
        case .added: "Added"
        case .removed: "Removed"
        case .keyArea: "Key area bar"
        case .draft: "Drafts (system accent unless set)"
        case .outdated: "Drafts outdated by a push"
        case .mine: "Your threads and comments"
        case .others: "Threads started by others"
        case .keyword: "Keywords"
        case .string: "Strings"
        case .comment: "Comments"
        case .number: "Numbers"
        case .call: "Function calls"
        }
    }
}

/// A few diff lines in a theme, to see a change as it's made.
struct ThemePreview: View {
    var theme: Theme

    private static let lines: [(new: Int?, change: DiffChange?, text: String)] = [
        (12, nil, "func total(_ items: [Item]) -> Int {"),
        (nil, .removed, "    // TODO: discounts"),
        (13, .modified, "    let sum = items.map(price).reduce(0, +)"),
        (14, .added, "    return apply(\"VIP\", to: sum * 2)"),
        (15, nil, "}"),
    ]

    var body: some View {
        let colors = palette(theme)
        let color = { (key: ThemeKey) in colors[key] ?? .accentColor }
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -12,4 +12,4 @@").foregroundStyle(color(.lineNumber))
                .padding(.vertical, 3).padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(.fold))
            ForEach(Self.lines.indices, id: \.self) { index in
                let line = Self.lines[index]
                HStack(spacing: 0) {
                    Text(line.new.map(String.init) ?? "").foregroundStyle(color(.lineNumber)).frame(width: 22, alignment: .trailing)
                    Rectangle().fill(color(.separator)).frame(width: 1).padding(.horizontal, 4)
                    Text(highlighted(line.text, color))
                        .lineLimit(1)
                        .overlay(alignment: .leading) { if index == 2 { color(.keyArea).frame(width: 3).offset(x: -4) } }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .background(line.change.map { color($0 == .added ? .added : $0 == .removed ? .removed : .modified) } ?? .clear)
            }
            HStack(spacing: 6) {
                Badge(text: "Draft", color: color(.draft))
                Badge(text: "Outdated by push", color: color(.outdated))
            }
            .padding(6)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .background(color(.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func highlighted(_ text: String, _ color: (ThemeKey) -> Color) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = color(.text)
        for token in Syntax.tokens(text, language: Syntax.language(for: "Preview.swift")!) {
            let start = result.index(result.startIndex, offsetByCharacters: token.range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: token.range.upperBound)
            result[start..<end].foregroundColor = color(.syntax(token.kind))
        }
        return result
    }
}

/// A theme as a file, for Export.
struct ThemeDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var theme: Theme

    init(theme: Theme) { self.theme = theme }

    init(configuration: ReadConfiguration) throws {
        theme = try Theme.decode(configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try theme.encoded())
    }
}

// MARK: - Import from IDE

struct IDEImport: Identifiable {
    let id = UUID()
    /// A VS Code or JetBrains file chosen with Import…; nil lists the installed IDEs.
    var file: IDETheme?
}

/// Lists the installed IDEs with their current theme, then shows what a chosen one gives before saving it.
/// Detection runs when the sheet opens and only reads the IDEs' files.
struct IDEImportSheet: View {
    var file: IDETheme?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var sources: [IDESource]?
    @ViewState private var chosen: [IDETheme]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chosen == nil ? "Import from IDE" : "Import “\(chosen!.map(\.name).joined(separator: " / "))”").font(.title3.bold())
            if let chosen {
                review(chosen)
            } else if let sources {
                list(sources)
            } else {
                ProgressView("Looking for VS Code, Cursor and JetBrains IDEs…").frame(maxWidth: .infinity)
            }
            HStack {
                if chosen != nil, file == nil { Button("Back") { chosen = nil } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let chosen {
                    Button("Import") {
                        ThemeStore.shared.importIDE(chosen)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            if let file {
                chosen = [file]
            } else {
                sources = await Task.detached { IDEThemes.detect() }.value
            }
        }
    }

    @ViewBuilder
    private func list(_ sources: [IDESource]) -> some View {
        if sources.isEmpty {
            Text("No VS Code, Cursor or JetBrains IDE found. Import… also reads a VS Code theme file or a JetBrains .icls scheme.")
                .foregroundStyle(.secondary)
        } else {
            Form {
                ForEach(sources) { source in
                    LabeledContent {
                        Button("Choose") { chosen = source.themes }.disabled(source.themes.isEmpty)
                    } label: {
                        Text(source.name)
                        if !source.themes.isEmpty { Text(source.themes.map(Self.label).joined(separator: " · ")) }
                        if let problem = source.problem { Text(problem).foregroundStyle(.orange) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 380)
        }
    }

    private func review(_ themes: [IDETheme]) -> some View {
        let result = Theme.imported(themes, into: ThemeStore.shared.current)
        let keys = ThemeKey.allCases.filter { ![.keyArea, .draft, .outdated].contains($0) } // IDEs have no such accents
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ThemePreview(theme: result).environment(\.colorScheme, .light)
                ThemePreview(theme: result).environment(\.colorScheme, .dark)
            }
            ForEach(themes.indices, id: \.self) { index in
                let theme = themes[index]
                let taken = keys.filter { theme.colors[$0] != nil }, fallback = keys.filter { theme.colors[$0] == nil }
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.label(theme)).bold()
                    if !taken.isEmpty { Text("From the IDE: " + taken.map(AppearanceSettings.title).joined(separator: ", ")) }
                    if !fallback.isEmpty { Text("Default: " + fallback.map(AppearanceSettings.title).joined(separator: ", ")).foregroundStyle(.secondary) }
                    if let note = theme.note { Text(note).foregroundStyle(.orange) }
                }
                .font(.callout)
            }
            if Set(themes.map(\.dark)).count == 1 {
                Text("The \(themes[0].dark ? "light" : "dark") colors stay as in “\(ThemeStore.shared.current.name)”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private static func label(_ theme: IDETheme) -> String {
        "\(theme.name) (\(theme.dark ? "dark" : "light"))"
    }
}

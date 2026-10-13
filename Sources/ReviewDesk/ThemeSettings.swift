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

    /// Reads a theme file and makes it the active theme. An invalid file throws and changes nothing.
    func importTheme(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var theme = try Theme.decode(Data(contentsOf: url))
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
        palette = [:]
        for key in ThemeKey.allCases {
            let light = current.color(key, dark: false), dark = current.color(key, dark: true)
            if light != nil || dark != nil { palette[key] = dynamicColor(light: light, dark: dark) }
        }
    }
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
    @ViewState private var error: String?
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
                    Button("Export…") { exporting = true }
                    Spacer()
                    Button("Delete", role: .destructive) { store.delete(store.selectedID) }
                        .disabled(store.saved[store.selectedID] == nil)
                    Button("Reset") { store.selectedID = "" }
                        .disabled(store.selectedID.isEmpty)
                        .help("Use the default colors again. Saved themes stay in the menu.")
                }
                HStack(spacing: 12) {
                    ThemePreview().environment(\.colorScheme, .light)
                    ThemePreview().environment(\.colorScheme, .dark)
                }
            } header: {
                Text("Color theme")
            } footer: {
                Text("Changing a color of the Default theme saves a copy named Custom. Theme files are JSON with a light and a dark hex value per color; colors a file leaves out use the default.")
            }
            colors("Editor", [.background, .text, .lineNumber, .separator, .fold])
            colors("Diff", [.modified, .added, .removed])
            colors("Accents", [.keyArea, .draft, .outdated])
            colors("Syntax", [.keyword, .string, .comment, .number, .call])
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { try store.importTheme(from: result.get()) } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: ThemeDocument(theme: store.current.resolved()),
                      contentType: .json, defaultFilename: store.current.name) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .alert("Couldn't import the theme", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
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

    private static func title(_ key: ThemeKey) -> String {
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
        case .keyword: "Keywords"
        case .string: "Strings"
        case .comment: "Comments"
        case .number: "Numbers"
        case .call: "Function calls"
        }
    }
}

/// A few diff lines in the active theme, to see a change as it's made.
private struct ThemePreview: View {
    private static let lines: [(old: Int?, new: Int?, change: DiffChange?, text: String)] = [
        (12, 12, nil, "func total(_ items: [Item]) -> Int {"),
        (13, nil, .removed, "    // TODO: discounts"),
        (14, 13, .modified, "    let sum = items.map(price).reduce(0, +)"),
        (nil, 14, .added, "    return apply(\"VIP\", to: sum * 2)"),
        (15, 15, nil, "}"),
    ]

    var body: some View {
        let language = Syntax.language(for: "Preview.swift")!
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -12,4 +12,4 @@").foregroundStyle(DiffColors.lineNumber)
                .padding(.vertical, 3).padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffColors.fold)
            ForEach(Self.lines.indices, id: \.self) { index in
                let line = Self.lines[index]
                HStack(spacing: 0) {
                    Text(line.new.map(String.init) ?? "").foregroundStyle(DiffColors.lineNumber).frame(width: 22, alignment: .trailing)
                    Rectangle().fill(DiffColors.separator).frame(width: 1).padding(.horizontal, 4)
                    Text(FileDiffView.highlighted(line.text, tokens: Syntax.tokens(line.text, language: language)))
                        .lineLimit(1)
                        .overlay(alignment: .leading) { if index == 2 { DiffColors.keyArea.frame(width: 3).offset(x: -4) } }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .background(DiffColors.block(line.change, side: line.change == .removed ? .left : .right))
            }
            HStack(spacing: 6) {
                Badge(text: "Draft", color: DiffColors.draft)
                Badge(text: "Outdated by push", color: DiffColors.outdated)
            }
            .padding(6)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .background(DiffColors.editor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
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

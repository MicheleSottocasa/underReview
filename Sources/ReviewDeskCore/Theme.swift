import Foundation

/// An sRGB color with alpha, written in theme files as `#RRGGBB` or `#RRGGBBAA` (`#RGB` and `#RGBA` are read too).
public struct HexColor: Codable, Hashable, Sendable {
    /// 0xRRGGBBAA.
    public var rgba: UInt32

    public init(_ rgb: UInt32, alpha: UInt8 = 0xFF) {
        rgba = (rgb & 0xFF_FFFF) << 8 | UInt32(alpha)
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        rgba = byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
    }

    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 || digits.count == 4 { digits = String(digits.flatMap { [$0, $0] }) }
        if digits.count == 6 { digits += "FF" }
        guard digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        rgba = value
    }

    public var hex: String {
        alpha == 1 ? String(format: "#%06X", rgba >> 8) : String(format: "#%08X", rgba)
    }

    public var red: Double { Double(rgba >> 24 & 0xFF) / 255 }
    public var green: Double { Double(rgba >> 16 & 0xFF) / 255 }
    public var blue: Double { Double(rgba >> 8 & 0xFF) / 255 }
    public var alpha: Double { Double(rgba & 0xFF) / 255 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = HexColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(text)” isn't a hex color like #1E1F22.")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// One theme entry: its color in light and in dark appearance. A missing side falls back to the built-in theme.
public struct ThemeColor: Codable, Hashable, Sendable {
    public var light: HexColor?
    public var dark: HexColor?

    public init(light: HexColor? = nil, dark: HexColor? = nil) {
        (self.light, self.dark) = (light, dark)
    }

    public subscript(dark dark: Bool) -> HexColor? {
        get { dark ? self.dark : light }
        set { if dark { self.dark = newValue } else { light = newValue } }
    }
}

/// The colors a theme sets. The raw values are the keys of a theme file's `colors`.
public enum ThemeKey: String, CaseIterable, Sendable {
    case background = "editor.background", text = "editor.text", lineNumber = "editor.lineNumber"
    case separator = "editor.separator", fold = "editor.fold"
    case modified = "diff.modified", added = "diff.added", removed = "diff.removed"
    case keyArea = "accent.keyArea", draft = "accent.draft", outdated = "accent.outdated"
    case keyword = "syntax.keyword", string = "syntax.string", comment = "syntax.comment"
    case number = "syntax.number", call = "syntax.call"

    /// A new `SyntaxKind` needs its own key here.
    public static func syntax(_ kind: SyntaxKind) -> ThemeKey {
        switch kind {
        case .keyword: .keyword
        case .string: .string
        case .comment: .comment
        case .number: .number
        case .call: .call
        }
    }
}

/// A color theme for the diff: a name and the colors it overrides. Anything it doesn't set, the built-in theme
/// (JetBrains' New UI colors) provides, so older or partial files keep working.
public struct Theme: Codable, Hashable, Sendable {
    public var name: String
    /// `ThemeKey` raw value → colors. Unknown keys are kept but unused.
    public var colors: [String: ThemeColor]

    public init(name: String, colors: [String: ThemeColor] = [:]) {
        (self.name, self.colors) = (name, colors)
    }

    private enum CodingKeys: String, CodingKey { case name, colors }

    /// A missing name is empty (Import names the theme after its file) and missing colors are the defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        colors = try container.decodeIfPresent([String: ThemeColor].self, forKey: .colors) ?? [:]
    }

    public static let `default` = Theme(name: "Default")

    /// The built-in colors. The draft accent has none: it follows the system accent color.
    public static let builtIn: [ThemeKey: ThemeColor] = [
        .background: pair(dark: 0x1E1F22, light: 0xFFFFFF),
        .text: pair(dark: 0xBCBEC4, light: 0x080808),
        .lineNumber: pair(dark: 0x6F737A, light: 0xAEB3C2),
        .separator: pair(dark: 0x393B40, light: 0xEBECF0),
        .fold: pair(dark: 0x2B2D30, light: 0xF2F3F5),
        .modified: pair(dark: 0x283A4A, light: 0xDBE8FB),
        .added: pair(dark: 0x294436, light: 0xDCF0DC),
        .removed: pair(dark: 0x3C3F44, light: 0xE6E7EA),
        // macOS's system yellow and orange, which these used before themes existed.
        .keyArea: ThemeColor(light: HexColor(0xFFCC00, alpha: 0xD9), dark: HexColor(0xFFD60A, alpha: 0xD9)),
        .outdated: pair(dark: 0xFF9F0A, light: 0xFF9500),
        .keyword: pair(dark: 0xCF8E6D, light: 0x0033B3),
        .string: pair(dark: 0x6AAB73, light: 0x067D17),
        .comment: pair(dark: 0x7A7E85, light: 0x8C8C8C),
        .number: pair(dark: 0x2AACB8, light: 0x1750EB),
        .call: pair(dark: 0x56A8F5, light: 0x00627A),
    ]

    private static func pair(dark: UInt32, light: UInt32) -> ThemeColor {
        ThemeColor(light: HexColor(light), dark: HexColor(dark))
    }

    /// The theme's own color, or nil when it doesn't set one.
    public subscript(key: ThemeKey, dark dark: Bool) -> HexColor? {
        get { colors[key.rawValue]?[dark: dark] }
        set {
            var entry = colors[key.rawValue] ?? ThemeColor()
            entry[dark: dark] = newValue
            colors[key.rawValue] = entry.light == nil && entry.dark == nil ? nil : entry
        }
    }

    /// The color to draw with: the theme's, else the built-in one. Nil only for the draft accent left to the system.
    public func color(_ key: ThemeKey, dark: Bool) -> HexColor? {
        self[key, dark: dark] ?? Self.builtIn[key]?[dark: dark]
    }

    /// Every color filled in, the built-in ones included: what Export writes, so the file is a complete template.
    public func resolved() -> Theme {
        var theme = self
        for key in ThemeKey.allCases {
            for dark in [false, true] { theme[key, dark: dark] = color(key, dark: dark) }
        }
        return theme
    }

    /// Theme files are small; anything bigger is refused before it's read.
    public static let maxFileSize = 1_000_000

    /// The contents of a file to import, refusing one too large to be a theme.
    public static func fileData(_ url: URL) throws -> Data {
        if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxFileSize {
            throw ThemeFileError("This file is too large to be a theme.")
        }
        return try Data(contentsOf: url)
    }

    /// Reads a theme file. Throws a `ThemeFileError` saying what's wrong on anything that isn't one
    /// (bad JSON, wrong shape, a bad hex value).
    public static func decode(_ data: Data) throws -> Theme {
        do {
            return try JSONDecoder().decode(Theme.self, from: data)
        } catch let error as DecodingError {
            throw ThemeFileError(error)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Why a file isn't a theme, in words a person can act on.
public struct ThemeFileError: LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }

    init(_ error: DecodingError) {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : " at “\(path)”"
        }
        switch error {
        case .keyNotFound(let key, let context): message = "“\(key.stringValue)” is missing\(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): message = "Unexpected value\(path(context)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            message = context.codingPath.isEmpty ? "This isn't a JSON file." : "Bad value\(path(context)): \(context.debugDescription)"
        @unknown default: message = error.localizedDescription
        }
    }

    public var errorDescription: String? { message }
}

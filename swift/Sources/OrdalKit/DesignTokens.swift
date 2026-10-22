import Foundation

// Design tokens shared by every app. Values are plain numbers so each UI layer
// (SwiftUI/AppKit on macOS, SwiftCrossUI on Linux and Windows) turns them into
// its own colour and length types. Change a value here and all apps follow.

/// Spacing on an 8 pt grid; 4 pt only for fine-tuning inside dense controls.
public enum Space {
    public static let hairline: Double = 4
    public static let s: Double = 8
    public static let m: Double = 16
    public static let l: Double = 24
    public static let xl: Double = 32
}

/// A colour with separate light and dark values as `0xRRGGBB`
/// (both chosen for WCAG AA contrast on the window background).
public struct ColorPair: Equatable, Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// The same colour in both appearances.
    public init(_ rgb: UInt32) {
        self.init(light: rgb, dark: rgb)
    }

    public func rgb(dark isDark: Bool) -> UInt32 { isDark ? dark : light }

    /// Red, green and blue in 0...1.
    public static func components(_ rgb: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    /// Parses `#RRGGBB` or `RRGGBB`; nil for anything else.
    public static func parseHex(_ text: String) -> UInt32? {
        let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }
}

/// How a grid cell's text is coloured.
public enum DataRole: Equatable, Sendable {
    case number, bool, date, json
    /// NULL, UUIDs and bytes: the platform's secondary label colour.
    case muted
    /// The platform's normal label colour.
    case plain
}

/// Grid text colours per value kind. Contrast ≥ 4.5:1 in both appearances.
public enum DataPalette {
    public static let number = ColorPair(light: 0x0B5CAD, dark: 0x79B8FF)
    public static let bool = ColorPair(light: 0x8A3FB5, dark: 0xD2A8FF)
    public static let date = ColorPair(light: 0x8A4B00, dark: 0xF0B37E)
    public static let json = ColorPair(light: 0x1E7A3A, dark: 0x85E89D)
    /// Background of cells with unsaved edits.
    public static let staged = ColorPair(light: 0xFFF3B0, dark: 0x5C4A00)

    public static func role(for kind: ValueKind, value: Value) -> DataRole {
        if value.isNull { return .muted }
        switch kind {
        case .int, .float, .decimal: return .number
        case .bool: return .bool
        case .date, .time, .timestamp, .timestampTz: return .date
        case .json: return .json
        case .uuid, .bytes: return .muted
        case .text, .other: break
        }
        // Columns of unknown kind (Redis replies, expressions) colour by value.
        switch value {
        case .int, .float, .decimal: return .number
        case .bool: return .bool
        case .json: return .json
        default: return .plain
        }
    }

    /// The colour for a role, or nil for `.muted` / `.plain` (use the platform's label colours).
    public static func colors(for role: DataRole) -> ColorPair? {
        switch role {
        case .number: number
        case .bool: bool
        case .date: date
        case .json: json
        case .muted, .plain: nil
        }
    }
}

/// SQL editor highlighting.
public enum SyntaxPalette {
    public static let keyword = ColorPair(light: 0xA626A4, dark: 0xC678DD)
    public static let string = ColorPair(light: 0x1E7A3A, dark: 0x98C379)
}

extension EnvironmentTag {
    /// Text/background colour for the environment pill and the window edge.
    public var colors: ColorPair {
        switch self {
        case .local: ColorPair(light: 0x5F6368, dark: 0x9AA0A6)
        case .dev: ColorPair(light: 0x1E7A3A, dark: 0x3FB950)
        case .staging: ColorPair(light: 0x8A4B00, dark: 0xD29922)
        case .prod: ColorPair(light: 0xB3261E, dark: 0xF85149)
        }
    }

    /// Local connections get no coloured chrome: calm by default.
    public var showsChrome: Bool { self != .local }
}

extension ConnectionConfig {
    /// The connection's own colour tag when set, otherwise its environment colour.
    public var accentColors: ColorPair {
        if let rgb = colorTag.flatMap(ColorPair.parseHex) { return ColorPair(rgb) }
        return environment.colors
    }

    /// `host:port/db` (or the file path for SQLite), for cards and tooltips.
    public var address: String {
        switch kind {
        case .sqlite: host
        default: "\(host):\(port)" + (database.isEmpty ? "" : "/\(database)")
        }
    }

    /// Environment, engine and read-only flag, e.g. `Production · PostgreSQL · read-only`.
    public var subtitle: String {
        var parts = [kind.label]
        if environment.showsChrome { parts.insert(environment.label, at: 0) }
        if readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }
}

/// The app's light / dark choice. "System" follows the OS.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public static let storageKey = "appTheme"
    /// The relations canvas can differ from the app (e.g. a dark diagram in a light app).
    public static let diagramKey = "diagramTheme"

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    public static var currentDiagram: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: diagramKey) ?? "") ?? .system
    }

    /// Remembers the choice; each app applies it to its windows.
    public static func save(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: storageKey)
    }
}

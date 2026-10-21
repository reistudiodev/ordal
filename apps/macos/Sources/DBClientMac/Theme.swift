import AppKit
import DBClientKit
import SwiftUI

/// Spacing on an 8 pt grid; 4 pt only for fine-tuning inside dense controls.
enum Space {
    static let hairline: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Fonts {
    static let data = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let dataItalic = NSFontManager.shared.convert(data, toHaveTrait: .italicFontMask)
    static let editor = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

extension NSColor {
    /// A colour with separate light and dark values (both chosen for WCAG AA on the window background).
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Grid text colours per value kind. Contrast ≥ 4.5:1 in both appearances.
enum DataColors {
    static let number = NSColor.adaptive(light: 0x0B5CAD, dark: 0x79B8FF)
    static let bool = NSColor.adaptive(light: 0x8A3FB5, dark: 0xD2A8FF)
    static let date = NSColor.adaptive(light: 0x8A4B00, dark: 0xF0B37E)
    static let json = NSColor.adaptive(light: 0x1E7A3A, dark: 0x85E89D)

    static func color(for kind: ValueKind, value: Value) -> NSColor {
        if value.isNull { return .secondaryLabelColor }
        switch kind {
        case .int, .float, .decimal: return number
        case .bool: return bool
        case .date, .time, .timestamp, .timestampTz: return date
        case .json: return json
        case .uuid, .bytes: return .secondaryLabelColor
        case .text, .other: break
        }
        // Columns of unknown kind (Redis replies, expressions) colour by value.
        switch value {
        case .int, .float, .decimal: return number
        case .bool: return bool
        case .json: return json
        default: return .labelColor
        }
    }
}

extension EnvironmentTag {
    /// Text/background colour for the environment pill and the window edge.
    var nsColor: NSColor {
        switch self {
        case .local: .adaptive(light: 0x5F6368, dark: 0x9AA0A6)
        case .dev: .adaptive(light: 0x1E7A3A, dark: 0x3FB950)
        case .staging: .adaptive(light: 0x8A4B00, dark: 0xD29922)
        case .prod: .adaptive(light: 0xB3261E, dark: 0xF85149)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Local connections get no coloured chrome: calm by default.
    var showsChrome: Bool { self != .local }
}

extension ConnectionConfig: @retroactive Identifiable {}
extension ConnectionFormModel: @retroactive Identifiable {}

extension ConnectionConfig {
    var accent: Color {
        if let hex = colorTag.flatMap({ UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) }) {
            return Color(nsColor: NSColor(hex: hex))
        }
        return environment.color
    }

    /// `host:port/db` (or the file path for SQLite), for cards and tooltips.
    var address: String {
        switch kind {
        case .sqlite: host
        default: "\(host):\(port)" + (database.isEmpty ? "" : "/\(database)")
        }
    }
}

extension NodeKind {
    var symbol: String {
        switch self {
        case .database: "cylinder"
        case .schema: "square.stack.3d.up"
        case .folder: "folder"
        case .table: "tablecells"
        case .view: "eye"
        case .function: "function"
        case .column: "line.3.horizontal"
        case .collection: "doc.on.doc"
        case .index: "list.number"
        case .keyPrefix: "folder"
        case .key: "key"
        }
    }
}

/// A small rounded label, e.g. the environment tag.
struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

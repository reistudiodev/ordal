import AppKit
import OrdalKit
import SwiftUI

// Spacing (`Space`) and colour values come from OrdalKit's DesignTokens, shared with Linux and Windows.
typealias Space = OrdalKit.Space

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

    static func adaptive(_ pair: ColorPair) -> NSColor {
        adaptive(light: pair.light, dark: pair.dark)
    }

    convenience init(hex: UInt32) {
        let c = ColorPair.components(hex)
        self.init(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

/// Grid text colours per value kind. Contrast ≥ 4.5:1 in both appearances.
enum DataColors {
    static let number = NSColor.adaptive(DataPalette.number)
    static let bool = NSColor.adaptive(DataPalette.bool)
    static let date = NSColor.adaptive(DataPalette.date)
    static let json = NSColor.adaptive(DataPalette.json)
    /// Background of cells with unsaved edits.
    static let staged = NSColor.adaptive(DataPalette.staged)

    static func color(for kind: ValueKind, value: Value) -> NSColor {
        switch DataPalette.role(for: kind, value: value) {
        case .number: number
        case .bool: bool
        case .date: date
        case .json: json
        case .muted: .secondaryLabelColor
        case .plain: .labelColor
        }
    }
}

extension EnvironmentTag {
    /// Text/background colour for the environment pill and the window edge.
    var nsColor: NSColor { .adaptive(colors) }

    var color: Color { Color(nsColor: nsColor) }
}

extension ConnectionConfig: @retroactive Identifiable {}
extension ConnectionFormModel: @retroactive Identifiable {}

extension ConnectionConfig {
    var accent: Color { Color(nsColor: .adaptive(accentColors)) }
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

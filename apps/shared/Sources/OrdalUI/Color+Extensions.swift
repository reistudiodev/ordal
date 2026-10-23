import OrdalKit
import SwiftCrossUI

extension Color {
    /// Creates a SwiftCrossUI adaptive Color from an OrdalKit ColorPair.
    public static func from(pair: ColorPair) -> Color {
        let l = ColorPair.components(pair.light)
        let d = ColorPair.components(pair.dark)
        return Color.adaptive(
            light: Color(red: l.red, green: l.green, blue: l.blue),
            dark: Color(red: d.red, green: d.green, blue: d.blue)
        )
    }

    /// Creates a SwiftCrossUI Color from a 0xRRGGBB hex integer.
    public static func hex(_ rgb: UInt32) -> Color {
        let c = ColorPair.components(rgb)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    // MARK: - Modern UI Semantic Palette (Inspired by Supabase Studio, Zed, TablePlus)

    public static let uiBackground = Color.adaptive(
        light: Color.hex(0xF8F9FA),
        dark: Color.hex(0x0F141C)
    )

    public static let uiSidebar = Color.adaptive(
        light: Color.hex(0xF1F3F5),
        dark: Color.hex(0x131822)
    )

    public static let uiPanel = Color.adaptive(
        light: Color.hex(0xFFFFFF),
        dark: Color.hex(0x181F2C)
    )

    public static let uiHover = Color.adaptive(
        light: Color.hex(0xE9ECEF),
        dark: Color.hex(0x222B3D)
    )

    public static let uiBorder = Color.adaptive(
        light: Color.hex(0xE2E8F0),
        dark: Color.hex(0x232C3D)
    )

    public static let uiAccent = Color.adaptive(
        light: Color.hex(0x2563EB),
        dark: Color.hex(0x3B82F6)
    )

    public static let uiTextPrimary = Color.adaptive(
        light: Color.hex(0x0F172A),
        dark: Color.hex(0xF1F5F9)
    )

    public static let uiTextMuted = Color.adaptive(
        light: Color.hex(0x64748B),
        dark: Color.hex(0x94A3B8)
    )

    public static let uiTextFaint = Color.adaptive(
        light: Color.hex(0x94A3B8),
        dark: Color.hex(0x64748B)
    )

    public static let uiSuccess = Color.hex(0x10B981)
    public static let uiWarning = Color.hex(0xF59E0B)
    public static let uiDanger = Color.hex(0xEF4444)

    // MARK: - Schema Node Colors

    public static let nodeTable = Color.hex(0x38BDF8)     // Sky Blue
    public static let nodeView = Color.hex(0x34D399)      // Mint Emerald
    public static let nodeFunction = Color.hex(0xFBBF24)  // Amber Gold
    public static let nodeDatabase = Color.hex(0xA78BFA)  // Purple Violet
    public static let nodeFolder = Color.hex(0x94A3B8)    // Cool Slate
    public static let nodeKey = Color.hex(0xFB923C)       // Orange
    public static let nodeIndex = Color.hex(0xC084FC)     // Light Violet
    public static let nodeColumn = Color.hex(0x94A3B8)    // Muted Slate
}

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
}

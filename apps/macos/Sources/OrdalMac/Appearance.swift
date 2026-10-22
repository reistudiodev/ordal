import AppKit
import OrdalKit
import SwiftUI

/// macOS mappings for OrdalKit's `AppTheme` (the shared light / dark choice).
extension AppTheme {
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Applies a theme to every window and remembers it.
    @MainActor
    static func set(_ theme: AppTheme) {
        save(theme)
        NSApp.appearance = theme.nsAppearance
    }
}

/// Settings (⌘,): appearance for now.
struct SettingsView: View {
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system.rawValue
    @AppStorage(AppTheme.diagramKey) private var diagramTheme = AppTheme.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(AppTheme.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Relations diagram", selection: $diagramTheme) {
                Text("Match App").tag(AppTheme.system.rawValue)
                Text("Always Light").tag(AppTheme.light.rawValue)
                Text("Always Dark").tag(AppTheme.dark.rawValue)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onChange(of: theme) { AppTheme.set(AppTheme(rawValue: theme) ?? .system) }
    }
}

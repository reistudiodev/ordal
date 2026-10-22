import AppKit
import SwiftUI

/// The app's light / dark choice. "System" follows macOS.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "appTheme"
    /// The relations canvas can differ from the app (e.g. a dark diagram in a light app).
    static let diagramKey = "diagramTheme"

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

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

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// Applies a theme to every window and remembers it.
    @MainActor
    static func set(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: storageKey)
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

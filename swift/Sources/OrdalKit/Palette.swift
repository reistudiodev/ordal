import Foundation
import Observation

/// One command palette entry. The app builds the list; the palette filters it.
public struct PaletteCommand: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let shortcut: String?
    public let action: @MainActor () -> Void

    public init(id: String, title: String, subtitle: String? = nil, shortcut: String? = nil, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.action = action
    }
}

@MainActor @Observable
public final class PaletteModel {
    public var query = "" {
        didSet { selection = 0 }
    }
    public private(set) var selection = 0
    private let commands: [PaletteCommand]

    public init(commands: [PaletteCommand]) {
        self.commands = commands
    }

    public var results: [PaletteCommand] {
        Fuzzy.filter(commands, query: query) { [$0.title, $0.subtitle ?? ""].joined(separator: " ") }
    }

    public func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Runs the highlighted command; returns false when nothing matched.
    @discardableResult
    public func runSelected() -> Bool {
        let r = results
        guard r.indices.contains(selection) else { return false }
        r[selection].action()
        return true
    }
}

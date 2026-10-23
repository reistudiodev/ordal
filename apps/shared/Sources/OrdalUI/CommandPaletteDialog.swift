import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

public struct CommandPaletteItem: Identifiable {
    public let id: String
    public let command: PaletteCommand

    public init(command: PaletteCommand) {
        self.id = command.id
        self.command = command
    }
}

/// Global floating command palette modal for fast fuzzy-searching actions and tables.
public struct CommandPaletteDialog: View {
    let container: AppStateContainer
    let onDismiss: () -> Void

    @State private var query: String = ""

    public init(container: AppStateContainer, onDismiss: @escaping () -> Void) {
        self.container = container
        self.onDismiss = onDismiss
    }

    private var allCommands: [PaletteCommand] {
        PaletteCommands.build(app: container.app, container: container)
    }

    private var filteredCommands: [CommandPaletteItem] {
        let list = allCommands
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return list.map { CommandPaletteItem(command: $0) }
        }
        let filtered = Fuzzy.filter(list, query: query) { [$0.title, $0.subtitle ?? ""].joined(separator: " ") }
        return filtered.map { CommandPaletteItem(command: $0) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchHeader
            resultsList
            footerHint
        }
        .frame(minWidth: 520, maxWidth: 640)
        .background(Color.uiPanel)
        .cornerRadius(8)
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            ModernIcon(.search, color: Color.uiTextMuted, size: 14)

            TextField(
                "Search command, table, or connection...",
                text: Binding(
                    get: { query },
                    set: { newText in
                        query = newText
                        container.notifyUpdate()
                    }
                )
            )

            Button {
                onDismiss()
            } label: {
                ModernIcon(.close, color: Color.uiTextMuted, size: 11)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.uiSidebar)
    }

    private var resultsList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                let results = filteredCommands
                if results.isEmpty {
                    HStack {
                        Spacer()
                        Text("No matching commands found")
                            .font(.body)
                            .foregroundColor(Color.uiTextMuted)
                            .padding(24)
                        Spacer()
                    }
                } else {
                    ForEach(results, id: \.id) { item in
                        CommandRowView(command: item.command) {
                            onDismiss()
                            item.command.action()
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 380)
    }

    private var footerHint: some View {
        HStack {
            Text("Tip: Click any item or use search to quickly jump to tables or run actions.")
                .font(.caption)
                .foregroundColor(Color.uiTextMuted)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Text("Close")
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.uiSidebar)
    }
}

private struct CommandRowView: View {
    let command: PaletteCommand
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                    if let sub = command.subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundColor(Color.uiTextMuted)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundColor(Color.uiAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.uiHover)
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}


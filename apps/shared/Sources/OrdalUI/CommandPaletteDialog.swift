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
            // Header & Search input
            HStack(spacing: 8) {
                Text("🔍")
                    .font(.body)

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

                Button("✕") {
                    onDismiss()
                }
            }
            .padding(12)
            .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.2)))

            // Results list
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    let results = filteredCommands
                    if results.isEmpty {
                        HStack {
                            Spacer()
                            Text("No matching commands found")
                                .font(.body)
                                .foregroundColor(Color(white: 0.5))
                                .padding(24)
                            Spacer()
                        }
                    } else {
                        ForEach(results, id: \.id) { item in
                            let cmd = item.command
                            Button {
                                onDismiss()
                                cmd.action()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cmd.title)
                                            .font(.body)
                                        if let sub = cmd.subtitle {
                                            Text(sub)
                                                .font(.caption)
                                                .foregroundColor(Color(white: 0.5))
                                        }
                                    }

                                    Spacer()

                                    if let shortcut = cmd.shortcut {
                                        Text(shortcut)
                                            .font(.caption)
                                            .foregroundColor(Color.hex(0x007ACC))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 380)

            // Footer hint
            HStack {
                Text("Tip: Click any item or use search to quickly jump to tables or run actions.")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Button("Close") {
                    onDismiss()
                }
            }
            .padding(10)
            .background(Color.adaptive(light: Color(white: 0.96), dark: Color(white: 0.16)))
        }
        .frame(minWidth: 520, maxWidth: 640)
        .background(Color.adaptive(light: Color(white: 1.0), dark: Color(white: 0.18)))
        .cornerRadius(8)
    }
}

@MainActor
public enum PaletteCommands {
    public static func build(app: AppState, container: AppStateContainer) -> [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(id: "new-connection", title: "New Connection…", shortcut: "Ctrl+N") {
                app.newConnection()
                container.notifyUpdate()
            },
            PaletteCommand(id: "welcome", title: "Show Saved Connections", shortcut: "Ctrl+H") {
                app.showWelcome = true
                container.notifyUpdate()
            },
            PaletteCommand(id: "theme-light", title: "Appearance: Light Theme") {
                AppTheme.save(.light)
                container.notifyUpdate()
            },
            PaletteCommand(id: "theme-dark", title: "Appearance: Dark Theme") {
                AppTheme.save(.dark)
                container.notifyUpdate()
            },
            PaletteCommand(id: "theme-system", title: "Appearance: System Default") {
                AppTheme.save(.system)
                container.notifyUpdate()
            },
        ]

        if let ws = app.activeWorkspace {
            list += [
                PaletteCommand(id: "new-tab", title: "New Query Tab", shortcut: "Ctrl+T") {
                    ws.newQueryTab()
                    container.notifyUpdate()
                },
                PaletteCommand(id: "disconnect", title: "Disconnect", subtitle: ws.config.name) {
                    Task {
                        await app.disconnect(ws.id)
                        container.notifyUpdate()
                    }
                },
                PaletteCommand(id: "reconnect", title: "Reconnect", subtitle: ws.config.name, shortcut: "Ctrl+R") {
                    Task {
                        await ws.reconnect()
                        container.notifyUpdate()
                    }
                },
                PaletteCommand(id: "edit-connection", title: "Edit Current Connection…", subtitle: ws.config.name) {
                    app.edit(ws.config)
                    container.notifyUpdate()
                },
            ]

            if let q = ws.activeEditor {
                list += [
                    PaletteCommand(id: "run-query", title: "Run Active Query", shortcut: "Ctrl+Enter") {
                        Task {
                            await q.run()
                            container.notifyUpdate()
                        }
                    },
                    PaletteCommand(id: "cancel-query", title: "Cancel Query Execution", shortcut: "Esc") {
                        q.cancel()
                        container.notifyUpdate()
                    },
                ]
                if ws.config.kind.isSQL {
                    list.append(PaletteCommand(id: "format-sql", title: "Format SQL Query", shortcut: "Ctrl+Shift+F") {
                        q.format()
                        container.notifyUpdate()
                    })
                }
            }

            if let id = ws.selectedTabID {
                list.append(PaletteCommand(id: "close-tab", title: "Close Current Tab", shortcut: "Ctrl+W") {
                    ws.closeTab(id)
                    container.notifyUpdate()
                })
            }

            for node in ws.browser.loadedNodes where node.opensAsTable {
                list.append(PaletteCommand(
                    id: "open-table:" + node.id,
                    title: "Open Table: \(node.name)",
                    subtitle: node.path.dropLast().joined(separator: " › ")
                ) {
                    ws.openTable(node)
                    container.notifyUpdate()
                })
            }

            for node in ws.browser.loadedNodes {
                if let path = ws.relationsPath(for: node) {
                    list.append(PaletteCommand(
                        id: "schema:" + node.id,
                        title: "View Schema Relations: \(node.name)"
                    ) {
                        ws.openSchema(path: path)
                        container.notifyUpdate()
                    })
                }
            }
        }

        for c in app.connections {
            list.append(PaletteCommand(
                id: "switch-to:" + c.id,
                title: "Switch to: \(c.name)",
                subtitle: "\(c.kind.label) · \(c.environment.label)"
            ) {
                Task {
                    await app.connect(c.id)
                    container.notifyUpdate()
                }
            })
        }

        return list
    }
}

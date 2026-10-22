import Foundation
import OrdalCore
import OrdalKit

/// Factory for building context-aware command palette actions.
@MainActor
public enum PaletteCommands {
    public static func build(app: AppState, container: AppStateContainer) -> [PaletteCommand] {
        var list = globalCommands(app: app, container: container)

        if let ws = app.activeWorkspace {
            list += workspaceCommands(ws: ws, app: app, container: container)
        }

        list += connectionSwitchCommands(app: app, container: container)
        return list
    }

    private static func globalCommands(app: AppState, container: AppStateContainer) -> [PaletteCommand] {
        [
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
    }

    private static func workspaceCommands(
        ws: WorkspaceModel,
        app: AppState,
        container: AppStateContainer
    ) -> [PaletteCommand] {
        var list: [PaletteCommand] = [
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
            list += editorCommands(q: q, isSQL: ws.config.kind.isSQL, container: container)
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

        return list
    }

    private static func editorCommands(
        q: QueryTabModel,
        isSQL: Bool,
        container: AppStateContainer
    ) -> [PaletteCommand] {
        var list = [
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
        if isSQL {
            list.append(PaletteCommand(id: "format-sql", title: "Format SQL Query", shortcut: "Ctrl+Shift+F") {
                q.format()
                container.notifyUpdate()
            })
        }
        return list
    }

    private static func connectionSwitchCommands(
        app: AppState,
        container: AppStateContainer
    ) -> [PaletteCommand] {
        app.connections.map { c in
            PaletteCommand(
                id: "switch-to:" + c.id,
                title: "Switch to: \(c.name)",
                subtitle: "\(c.kind.label) · \(c.environment.label)"
            ) {
                Task {
                    await app.connect(c.id)
                    container.notifyUpdate()
                }
            }
        }
    }
}

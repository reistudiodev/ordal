import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern native cross-platform database workspace layout.
public struct WorkspaceView: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel

    private var app: AppState { container.app }

    public init(container: AppStateContainer, workspace: WorkspaceModel) {
        self.container = container
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(container: container, workspace: workspace)

            HStack(spacing: 0) {
                sidebarArea
                centerWorkArea

                if app.showInspector {
                    InspectorView(
                        container: container,
                        workspace: workspace,
                        onDismiss: {
                            app.showInspector = false
                            container.notifyUpdate()
                        }
                    )
                }
            }

            WorkspaceStatusBar(workspace: workspace)
        }
        .background(Color.uiBackground)
    }

    private var sidebarArea: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SCHEMA BROWSER")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.uiSidebar)

            ObjectBrowser(container: container, workspace: workspace)
        }
        .frame(minWidth: 230, maxWidth: 290)
        .background(Color.uiSidebar)
    }

    private var centerWorkArea: some View {
        VStack(spacing: 0) {
            WorkspaceTabBar(container: container, workspace: workspace)
            tabContentArea
        }
        .frame(minWidth: 400)
        .background(Color.uiBackground)
    }

    @ViewBuilder
    private var tabContentArea: some View {
        if let tab = workspace.selectedTab {
            switch tab {
            case .query(let queryTab):
                QueryTabView(container: container, tab: queryTab, workspace: workspace)
            case .table(let tableTab):
                TableTabView(container: container, tab: tableTab, workspace: workspace)
            case .schema(let schemaTab):
                SchemaDiagramTabView(container: container, tab: schemaTab, workspace: workspace)
            }
        } else {
            emptyTabPlaceholder
        }
    }

    private var emptyTabPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            ModernIcon(.table, color: Color.uiTextMuted, size: 36, strokeWidth: 1.2)
            Text("No open tabs")
                .font(.title2)
                .foregroundColor(Color.uiTextPrimary)
            Text("Select a table or view from the sidebar, or open a new query.")
                .font(.body)
                .foregroundColor(Color.uiTextMuted)
            Button {
                workspace.newQueryTab()
                container.notifyUpdate()
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(.plus, color: Color.uiAccent, size: 12)
                    Text("New Query Tab (Ctrl+T)")
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

private struct WorkspaceTopBar: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel

    private var app: AppState { container.app }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .foregroundColor(Color.from(pair: workspace.config.accentColors))
                .frame(width: 8, height: 8)

            Text(workspace.config.name)
                .font(.headline)
                .foregroundColor(Color.uiTextPrimary)

            if workspace.config.environment.showsChrome {
                Text(workspace.config.environment.label)
                    .font(.caption)
                    .foregroundColor(Color.from(pair: workspace.config.environment.colors))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.uiHover)
                    .cornerRadius(4)
            }

            if workspace.config.readOnly {
                Text("(read-only)")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)
            }

            Text("·")
                .foregroundColor(Color.uiTextFaint)

            Text(workspace.config.address)
                .font(.caption)
                .foregroundColor(Color.uiTextMuted)

            Spacer()

            // Command Palette (Ctrl+K)
            Button {
                app.showPalette = true
                container.notifyUpdate()
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(.search, color: Color.uiTextMuted, size: 12)
                    Text("Command (Ctrl+K)")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Inspector Toggle
            Button {
                app.showInspector.toggle()
                container.notifyUpdate()
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(
                        .inspector,
                        color: app.showInspector ? Color.uiAccent : Color.uiTextMuted,
                        size: 12
                    )
                    Text(app.showInspector ? "Hide Inspector" : "Inspector")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // New Query
            Button {
                workspace.newQueryTab()
                container.notifyUpdate()
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(.plus, color: Color.uiAccent, size: 12)
                    Text("New Query")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Reconnect
            Button {
                Task {
                    await workspace.reconnect()
                    container.notifyUpdate()
                }
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(.refresh, color: Color.uiTextMuted, size: 12)
                    Text("Reconnect")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Connections (Home)
            Button {
                app.showWelcome = true
                container.notifyUpdate()
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(.home, color: Color.uiTextMuted, size: 12)
                    Text("Connections")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // Disconnect
            Button {
                Task {
                    await app.disconnect(workspace.id)
                    container.notifyUpdate()
                }
            } label: {
                Text("Disconnect")
                    .font(.caption)
                    .foregroundColor(Color.uiDanger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.uiPanel)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.uiSidebar)
    }
}

private struct WorkspaceTabBar: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        let isSelected = tab.id == workspace.selectedTabID
                        HStack(spacing: 6) {
                            Button {
                                workspace.selectedTabID = tab.id
                                container.notifyUpdate()
                            } label: {
                                HStack(spacing: 6) {
                                    ModernIcon(
                                        iconForTab(tab),
                                        color: isSelected ? Color.uiAccent : Color.uiTextMuted,
                                        size: 12
                                    )
                                    Text(tab.title)
                                        .font(.system(size: 12))
                                        .foregroundColor(
                                            isSelected
                                                ? Color.uiTextPrimary
                                                : Color.uiTextMuted
                                        )
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                workspace.closeTab(tab.id)
                                container.notifyUpdate()
                            } label: {
                                ModernIcon(.close, color: Color.uiTextFaint, size: 9, strokeWidth: 1.6)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isSelected
                                ? Color.uiBackground
                                : Color.uiSidebar
                        )
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Button {
                workspace.newQueryTab()
                container.notifyUpdate()
            } label: {
                ModernIcon(.plus, color: Color.uiTextMuted, size: 12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .background(Color.uiSidebar)
    }

    private func iconForTab(_ tab: WorkspaceModel.Tab) -> IconType {
        switch tab {
        case .query:
            return .play
        case .table:
            return .table
        case .schema:
            return .schema
        }
    }
}

private struct WorkspaceStatusBar: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                let statusColor: Color = {
                    switch workspace.state {
                    case .connected: Color.uiSuccess
                    case .reconnecting: Color.uiWarning
                    case .lost: Color.uiDanger
                    }
                }()
                Circle()
                    .foregroundColor(statusColor)
                    .frame(width: 7, height: 7)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
            }

            if let server = workspace.serverInfo {
                Text("\(server.engine) \(server.version)")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)
            }

            if let ms = workspace.latencyMs {
                Text("\(Int(ms.rounded())) ms")
                    .font(.caption)
                    .foregroundColor(Color.uiTextFaint)
            }

            Spacer()

            if let editor = workspace.activeEditor, editor.isRunning {
                HStack(spacing: 6) {
                    ModernIcon(.refresh, color: Color.uiAccent, size: 11)
                    Text("Executing query...")
                        .font(.caption)
                        .foregroundColor(Color.uiAccent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.uiSidebar)
    }

    private var statusText: String {
        switch workspace.state {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting..."
        case .lost: "Disconnected"
        }
    }
}

import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform main database workspace layout.
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
            // Top Toolbar & Connection Header
            topBar

            // Main Content Area: Sidebar + Active Tab Content + Inspector
            HStack(spacing: 0) {
                // Left Sidebar: Object Browser (Databases, Schemas, Tables)
                VStack(spacing: 0) {
                    HStack {
                        Text("Schema Browser")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.adaptive(light: Color(white: 0.92), dark: Color(white: 0.16)))

                    ObjectBrowser(container: container, workspace: workspace)
                }
                .frame(minWidth: 220, maxWidth: 280)
                .background(Color.adaptive(light: Color(white: 0.96), dark: Color(white: 0.14)))

                // Center Main Work Area: TabBar + Tab Content
                VStack(spacing: 0) {
                    tabBar

                    // Tab Content
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
                        VStack(spacing: 12) {
                            Spacer()
                            Text("No open tabs")
                                .font(.title2)
                                .foregroundColor(Color(white: 0.5))
                            Text("Select a table from the sidebar or open a new query.")
                                .font(.body)
                                .foregroundColor(Color(white: 0.4))
                            Button("New Query Tab (Ctrl+T)") {
                                workspace.newQueryTab()
                                container.notifyUpdate()
                            }
                            Spacer()
                        }
                    }
                }
                .frame(minWidth: 400)

                // Right Sidebar: Inspector & Cell Editor
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

            // Bottom Status Bar
            statusBar
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 12) {
            // Environment / Connection Accent Dot
            Circle()
                .foregroundColor(Color.from(pair: workspace.config.accentColors))
                .frame(width: 10, height: 10)

            Text(workspace.config.name)
                .font(.headline)

            if workspace.config.environment.showsChrome {
                Text(workspace.config.environment.label)
                    .font(.caption)
                    .foregroundColor(Color.from(pair: workspace.config.environment.colors))
            }

            if workspace.config.readOnly {
                Text("(read-only)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            Text("·")
                .foregroundColor(Color(white: 0.4))

            Text(workspace.config.address)
                .font(.caption)
                .foregroundColor(Color(white: 0.5))

            Spacer()

            Button("🔍 Command (Ctrl+K)") {
                app.showPalette = true
                container.notifyUpdate()
            }

            Button(app.showInspector ? "Hide Inspector" : "Inspector") {
                app.showInspector.toggle()
                container.notifyUpdate()
            }

            Button("➕ New Query") {
                workspace.newQueryTab()
                container.notifyUpdate()
            }

            Button("🔄 Reconnect") {
                Task {
                    await workspace.reconnect()
                    container.notifyUpdate()
                }
            }

            Button("🏠 Connections") {
                app.showWelcome = true
                container.notifyUpdate()
            }

            Button("Disconnect") {
                Task {
                    await app.disconnect(workspace.id)
                    container.notifyUpdate()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color.adaptive(
                light: Color(white: 0.93),
                dark: Color(white: 0.18)
            )
        )
    }

    // MARK: - Tab Bar
    private var tabBar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        let isSelected = tab.id == workspace.selectedTabID
                        HStack(spacing: 6) {
                            Button(tab.title) {
                                workspace.selectedTabID = tab.id
                                container.notifyUpdate()
                            }
                            .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.6))

                            Button("✕") {
                                workspace.closeTab(tab.id)
                                container.notifyUpdate()
                            }
                            .font(.caption)
                            .foregroundColor(Color(white: 0.4))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected
                                ? Color.adaptive(light: Color(white: 1.0), dark: Color(white: 0.22))
                                : Color.adaptive(light: Color(white: 0.91), dark: Color(white: 0.16))
                        )
                        .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Button("＋") {
                workspace.newQueryTab()
                container.notifyUpdate()
            }
            .padding(.horizontal, 8)
        }
        .background(
            Color.adaptive(
                light: Color(white: 0.89),
                dark: Color(white: 0.14)
            )
        )
    }

    // MARK: - Status Bar
    private var statusBar: some View {
        HStack(spacing: 16) {
            // Connection Status Dot & Label
            HStack(spacing: 6) {
                let statusColor: Color = {
                    switch workspace.state {
                    case .connected: Color.hex(0x28A745)
                    case .reconnecting: Color.hex(0xFFC107)
                    case .lost: Color.hex(0xDC3545)
                    }
                }()
                Circle()
                    .foregroundColor(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.6))
            }

            if let server = workspace.serverInfo {
                Text("\(server.engine) \(server.version)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            if let ms = workspace.latencyMs {
                Text("\(Int(ms.rounded())) ms")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            if let editor = workspace.activeEditor, editor.isRunning {
                Text("Executing query...")
                    .font(.caption)
                    .foregroundColor(Color.hex(0x007ACC))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            Color.adaptive(
                light: Color(white: 0.94),
                dark: Color(white: 0.17)
            )
        )
    }

    private var statusText: String {
        switch workspace.state {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting..."
        case .lost: "Disconnected"
        }
    }
}

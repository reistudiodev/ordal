import DBClientKit
import SwiftUI

/// Rail + browser on the left, tabs in the centre, inspector on the right,
/// status bar at the bottom.
struct WorkspaceView: View {
    @Environment(AppState.self) private var app
    let workspace: WorkspaceModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            HStack(spacing: 0) {
                ConnectionRail()
                Divider()
                ObjectBrowser(workspace: workspace)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        } detail: {
            VStack(spacing: 0) {
                TabBar(workspace: workspace)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(workspace: workspace)
            }
        }
        .inspector(isPresented: $app.showInspector) {
            InspectorView(workspace: workspace)
                .inspectorColumnWidth(min: 240, ideal: 320, max: 560)
        }
        .environmentEdge(workspace.config)
        .navigationTitle(workspace.config.name)
        .navigationSubtitle(subtitle)
        .task(id: workspace.id) {
            // Keep the latency in the status bar fresh without being chatty.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await workspace.refreshLatency()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.selectedTab {
        case .query(let tab):
            QueryTabView(tab: tab, workspace: workspace).id(tab.id)
        case .table(let tab):
            TableTabView(tab: tab, workspace: workspace).id(tab.id)
        case nil:
            ContentUnavailableView {
                Label("No open tabs", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("Open a table from the sidebar, or start a query with ⌘T.")
            } actions: {
                Button("New Query") { workspace.newQueryTab() }
            }
        }
    }

    private var subtitle: String {
        var parts = [workspace.config.kind.label]
        if workspace.config.environment.showsChrome { parts.insert(workspace.config.environment.label, at: 0) }
        if workspace.config.readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }
}

/// Coloured dots for saved connections; the active one is ringed.
struct ConnectionRail: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: Space.s) {
            ForEach(app.connections) { config in
                let active = app.activeWorkspaceID == config.id
                Button {
                    Task { await app.connect(config.id) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(app.isOpen(config.id) ? config.accent : config.accent.opacity(0.25))
                            .frame(width: 24, height: 24)
                        Text(config.name.prefix(1).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(app.isOpen(config.id) ? .white : .primary)
                    }
                    .padding(Space.hairline)
                    .overlay(Circle().strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help("\(config.name) · \(config.address)")
                .accessibilityLabel("\(config.name), \(config.environment.label)\(app.isOpen(config.id) ? ", open" : "")")
                .contextMenu {
                    Button("Edit…") { app.edit(config) }
                    if app.isOpen(config.id) {
                        Button("Disconnect") { Task { await app.disconnect(config.id) } }
                    }
                }
            }
            Spacer()
            Button {
                app.newConnection()
            } label: {
                Image(systemName: "plus").frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("New connection (⌘N)")
            .accessibilityLabel("New connection")
        }
        .padding(.vertical, Space.s)
        .frame(width: 48)
    }
}

/// A thin environment-coloured edge at the top of the window, so a
/// production connection never looks like a local one.
private struct EnvironmentEdge: ViewModifier {
    let config: ConnectionConfig

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if config.environment.showsChrome {
                Rectangle()
                    .fill(config.accent)
                    .frame(height: 3)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func environmentEdge(_ config: ConnectionConfig) -> some View {
        modifier(EnvironmentEdge(config: config))
    }
}

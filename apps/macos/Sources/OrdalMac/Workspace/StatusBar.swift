import OrdalKit
import SwiftUI

/// A dot for the connection state; its menu reconnects or disconnects.
private struct ConnectionIndicator: View {
    @Environment(AppState.self) private var app
    let workspace: WorkspaceModel

    var body: some View {
        Menu {
            Button("Reconnect") { Task { await workspace.reconnect() } }
            Button("Disconnect") { Task { await app.disconnect(workspace.id) } }
        } label: {
            HStack(spacing: Space.hairline) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Connection: \(label). Click to reconnect or disconnect.")
    }

    private var label: String {
        switch workspace.state {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .lost: "Disconnected"
        }
    }

    private var color: Color {
        switch workspace.state {
        case .connected: .green
        case .reconnecting: .orange
        case .lost: .red
        }
    }
}

/// Server version, latency, and the active tab's row count and timing.
struct StatusBar: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: Space.m) {
            ConnectionIndicator(workspace: workspace)
            if workspace.config.environment.showsChrome {
                Pill(text: workspace.config.environment.label.uppercased(), color: workspace.config.accent)
            }
            if let info = workspace.serverInfo {
                Text("\(info.engine) \(info.version)").lineLimit(1)
            }
            if let ms = workspace.latencyMs {
                Text(ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms").help("Round-trip latency")
            }
            Spacer()
            tabStatus
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.m)
        .frame(height: 24)
    }

    @ViewBuilder
    private var tabStatus: some View {
        switch workspace.selectedTab {
        case .query(let q):
            if let pager = q.pager {
                let _ = pager.version
                if pager.columns.isEmpty, let n = pager.rowsAffected, !q.isRunning {
                    Text("\(n.formatted()) rows affected")
                } else {
                    Text("\(pager.rowCount.formatted()) rows\(pager.isTruncated ? " (first \(CursorPager.defaultCap.formatted()))" : pager.isDone ? "" : "…")")
                }
                Text(q.isRunning ? "running" : "\(pager.elapsedMs.formatted()) ms")
            }
        case .table(let t) where t.segment == .query:
            // The table's Query segment: same summary as a query tab.
            if let pager = t.query.pager {
                let _ = pager.version
                Text("\(pager.rowCount.formatted()) rows")
                Text(t.query.isRunning ? "running" : "\(pager.elapsedMs.formatted()) ms")
            }
        case .table(let t):
            let _ = t.pager.version
            if let ms = t.pager.elapsedMs {
                Text(t.pager.isLoading ? "fetching…" : "\(ms.formatted()) ms")
            }
            if let count = t.pager.count {
                Text("\(count.exact ? "" : "~")\(count.count.formatted()) rows")
            }
            if !t.pager.staged.isEmpty {
                Text("\(t.pager.staged.count) unsaved")
            }
        case .schema(let s):
            if let g = s.graph {
                Text("\(g.tables.count) tables · \(g.relations.count) relations")
            }
        case nil:
            EmptyView()
        }
    }
}

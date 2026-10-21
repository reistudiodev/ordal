import DBClientKit
import SwiftUI

/// Server version, latency, and the active tab's row count and timing.
struct StatusBar: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: Space.m) {
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
        case .table(let t):
            let _ = t.pager.version
            Text("\(t.pager.countIsExact ? "" : "~")\(t.pager.rowCount.formatted()) rows")
        case nil:
            EmptyView()
        }
    }
}

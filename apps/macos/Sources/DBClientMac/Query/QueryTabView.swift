import DBClientKit
import SwiftUI

/// Editor on top, results below, history in a drawer.
struct QueryTabView: View {
    @Bindable var tab: QueryTabModel
    let workspace: WorkspaceModel
    @State private var showHistory = false
    @AppStorage("editorFraction") private var editorFraction: Double = 0.4

    var body: some View {
        HStack(spacing: 0) {
            SplitPane(fraction: Binding(get: { CGFloat(editorFraction) }, set: { editorFraction = Double($0) })) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    QueryEditor(text: $tab.text, selection: $tab.selection, language: language)
                }
            } bottom: {
                ResultsPane(tab: tab, workspace: workspace)
            }
            if showHistory {
                Divider()
                HistoryDrawer(tab: tab)
                    .frame(width: 300)
            }
        }
        .sheet(item: Binding(get: { tab.pending.map(PendingItem.init) }, set: { if $0 == nil { tab.dismissPending() } })) { item in
            ConfirmStatementSheet(pending: item.pending, config: workspace.config) {
                Task { await tab.confirmPending() }
            } onCancel: {
                tab.dismissPending()
            }
        }
    }

    private var language: QueryEditor.Language {
        switch workspace.config.kind {
        case .mongoDb: .json
        case .redis: .redis
        default: .sql
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            if tab.isRunning {
                Button(role: .cancel) { tab.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel the running query (⌘.)")
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await tab.run() } } label: {
                    Label(tab.selection.length > 0 ? "Run Selection" : "Run", systemImage: "play.fill")
                }
                .help("Run (⌘↵)")
            }
            if let db = tab.database {
                Text(db).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let url = tab.fileURL {
                Label(url.lastPathComponent + (tab.isDirty ? " •" : ""), systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(url.path)
            }
            Spacer()
            if workspace.config.kind.isSQL {
                Button("Format") { tab.format() }
                    .help("Format SQL (⇧⌘F)")
            }
            Toggle(isOn: $showHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help("Query history")
        }
        .controlSize(.small)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.hairline + 2)
    }
}

private struct PendingItem: Identifiable {
    let pending: QueryTabModel.PendingConfirmation
    var id: String { pending.sql }
}

private struct ResultsPane: View {
    let tab: QueryTabModel
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = tab.notice {
                Label(notice, systemImage: "lock.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
                    .background(.yellow.opacity(0.15))
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab.status {
        case .idle where tab.pager == nil:
            ContentUnavailableView("Run a query", systemImage: "play", description: Text(hint))
        case .failed(let message):
            ScrollView {
                Label {
                    Text(message).textSelection(.enabled).font(.body.monospaced())
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
            }
        case .cancelled:
            ContentUnavailableView("Query cancelled", systemImage: "stop.circle")
        default:
            if let pager = tab.pager {
                let version = pager.version
                if pager.columns.isEmpty && !tab.isRunning {
                    ContentUnavailableView(
                        "Done",
                        systemImage: "checkmark.circle",
                        description: Text(pager.rowsAffected.map { "\($0.formatted()) rows affected" } ?? "The statement ran.")
                    )
                } else if pager.columns.isEmpty {
                    ProgressView("Running…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ResultGridView(
                        source: pager, version: version,
                        onSelectCell: { row, col in
                            if let r = pager.row(at: row) {
                                workspace.inspected = .init(column: pager.columns[col], value: r.cells[col], row: row, columnIndex: col)
                            }
                        },
                        onSortColumn: pager.canSort ? { pager.toggleSort(column: $0) } : nil
                    )
                    if pager.isTruncated {
                        Text("Showing the first \(CursorPager.defaultCap.formatted()) rows. Add a LIMIT or filter to see the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, Space.hairline)
                    }
                }
            } else {
                ProgressView("Running…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var hint: String {
        switch workspace.config.kind {
        case .mongoDb: "Type a JSON command such as {\"find\": \"users\", \"filter\": {}} and press ⌘↵."
        case .redis: "Type a command such as HGETALL user:1 and press ⌘↵."
        default: "Type SQL and press ⌘↵. With text selected, only the selection runs."
        }
    }
}

private struct HistoryDrawer: View {
    let tab: QueryTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(Space.s)
            Divider()
            if tab.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Queries you run on this connection appear here."))
            } else {
                List(Array(tab.history.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.query)
                            .font(.caption.monospaced())
                            .lineLimit(3)
                        HStack(spacing: Space.s) {
                            Image(systemName: entry.succeeded ? "checkmark" : "xmark")
                                .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)
                            Text(Date(timeIntervalSince1970: Double(entry.executedAtMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                            Text("\(entry.durationMs) ms")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { tab.text = entry.query }
                    .help("Double-click to put this query in the editor")
                }
            }
        }
    }
}

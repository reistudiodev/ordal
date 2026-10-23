import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Native cross-platform query editor, execution toolbar, and results pane.
public struct QueryTabView: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel

    @State private var showHistoryDialog = false

    public init(container: AppStateContainer, tab: QueryTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                QueryExecutionToolbar(
                    container: container,
                    tab: tab,
                    workspace: workspace,
                    onShowHistory: {
                        showHistoryDialog = true
                        container.notifyUpdate()
                    }
                )

                if let notice = tab.notice {
                    queryNoticeBanner(notice)
                }

                VStack(spacing: 0) {
                    TextEditor(text: Binding(get: { tab.text }, set: { tab.text = $0 }))
                        .frame(minHeight: 120, maxHeight: 240)
                        .padding(8)

                    resultsDividerBar

                    QueryResultsPane(
                        container: container,
                        tab: tab,
                        workspace: workspace
                    )
                }
            }

            if showHistoryDialog {
                historyDialogOverlay
            }
        }
    }

    private var historyDialogOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                QueryHistoryDialog(
                    container: container,
                    tab: tab,
                    onDismiss: {
                        showHistoryDialog = false
                        container.notifyUpdate()
                    }
                )
                Spacer()
            }
            Spacer()
        }
        .background(Color(white: 0.0, opacity: 0.5))
    }

    private func queryNoticeBanner(_ notice: String) -> some View {
        HStack {
            Text("⚠️ \(notice)")
                .font(.caption)
                .foregroundColor(Color.hex(0x856404))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.hex(0xFFF3CD))
    }

    private var resultsDividerBar: some View {
        HStack(spacing: 8) {
            Text("Results")
                .font(.caption)
                .foregroundColor(Color(white: 0.5))

            if let pager = tab.pager, !pager.columns.isEmpty {
                Text("•")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                Text("\(pager.rowCount) rows · ⚡ \(pager.elapsedMs) ms")
                    .font(.caption)
                    .foregroundColor(Color.hex(0x28A745))
            }

            Spacer()

            if let pager = tab.pager, !pager.columns.isEmpty {
                Button("📋 Copy CSV") {
                    #if os(macOS)
                    AppKit.NSPasteboard.general.clearContents()
                    AppKit.NSPasteboard.general.setString(pager.exportCSV(), forType: .string)
                    #endif
                }
                Button("📋 Copy JSON") {
                    #if os(macOS)
                    AppKit.NSPasteboard.general.clearContents()
                    AppKit.NSPasteboard.general.setString(pager.exportJSON(pretty: true), forType: .string)
                    #endif
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            Color.adaptive(
                light: Color(white: 0.9),
                dark: Color(white: 0.2)
            )
        )
    }
}

private struct QueryExecutionToolbar: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel
    let onShowHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            runOrCancelButton

            if workspace.config.kind.isSQL {
                Button("Format SQL") {
                    tab.format()
                    container.notifyUpdate()
                }
            }

            Button("📜 History (\(tab.history.count))") {
                onShowHistory()
            }

            if let db = tab.database ?? (workspace.config.database.isEmpty ? nil : workspace.config.database) {
                Text("Database: \(db)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            queryStatusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color.adaptive(
                light: Color(white: 0.95),
                dark: Color(white: 0.18)
            )
        )
    }

    @ViewBuilder
    private var runOrCancelButton: some View {
        if tab.isRunning {
            Button("⏹ Cancel") {
                tab.cancel()
                container.notifyUpdate()
            }
            Text("Executing query...")
                .font(.caption)
                .foregroundColor(Color(white: 0.6))
        } else {
            Button("▶ Run (Ctrl+Enter)") {
                Task {
                    await tab.run()
                    container.notifyUpdate()
                }
            }
        }
    }

    @ViewBuilder
    private var queryStatusView: some View {
        switch tab.status {
        case .idle:
            EmptyView()
        case .running:
            Text("Running...")
                .font(.caption)
                .foregroundColor(Color.hex(0x007ACC))
        case .finished:
            if let pager = tab.pager {
                let rowInfo = pager.rowsAffected != nil ? "\(pager.rowsAffected!) rows affected" : "\(pager.rowCount) rows"
                Text("Success · \(rowInfo) · \(pager.elapsedMs) ms")
                    .font(.caption)
                    .foregroundColor(Color.hex(0x28A745))
            }
        case .failed(let err):
            Text("Error: \(err)")
                .font(.caption)
                .foregroundColor(Color.hex(0xDC3545))
        case .cancelled:
            Text("Query cancelled")
                .font(.caption)
                .foregroundColor(Color(white: 0.5))
        }
    }
}

private struct QueryResultsPane: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel

    @State private var docMode: DocumentViewMode = .documents

    var body: some View {
        if let pager = tab.pager {
            if pager.hasDocuments {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(pager.rowCount) document(s)")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        Spacer()
                        Button(docMode == .table ? "🗂 Cards View" : "📊 Table View") {
                            docMode = (docMode == .table ? .documents : .table)
                            container.notifyUpdate()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.2)))

                    if docMode == .table {
                        resultGrid(pager: pager)
                    } else {
                        DocumentListView(
                            source: pager,
                            onSelectField: { rowIndex, _ in
                                guard let col = pager.columns.first,
                                      let row = pager.row(at: rowIndex) else { return }
                                let val = row.cells.first ?? Value.null
                                workspace.inspected = WorkspaceModel.InspectedCell(
                                    column: col,
                                    value: val,
                                    row: rowIndex,
                                    columnIndex: 0,
                                    tableTab: nil
                                )
                                container.app.showInspector = true
                                container.notifyUpdate()
                            }
                        )
                    }
                }
            } else {
                resultGrid(pager: pager)
            }
        } else if case .failed(let error) = tab.status {
            ScrollView(.vertical) {
                HStack {
                    Text("Execution Error:\n\n\(error)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color.hex(0xDC3545))
                        .padding(16)
                    Spacer()
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Write a query above and click Run (or press Ctrl+Enter)")
                    .foregroundColor(Color(white: 0.5))
                    .font(.body)
                Spacer()
            }
        }
    }

    private func resultGrid(pager: CursorPager) -> some View {
        ResultGrid(
            source: pager,
            onSelectCell: { rowIndex, colIndex in
                guard colIndex < pager.columns.count,
                      let row = pager.row(at: rowIndex) else { return }
                let col = pager.columns[colIndex]
                let val = colIndex < row.cells.count ? row.cells[colIndex] : Value.null
                workspace.inspected = WorkspaceModel.InspectedCell(
                    column: col,
                    value: val,
                    row: rowIndex,
                    columnIndex: colIndex,
                    tableTab: nil
                )
                container.app.showInspector = true
                container.notifyUpdate()
            },
            onSortColumn: { col in
                pager.toggleSort(column: col)
                container.notifyUpdate()
            }
        )
    }
}

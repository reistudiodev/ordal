import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Modern native cross-platform Query Tab View with syntax styling, run/cancel, history, and results.
public struct QueryTabView: View {
    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel

    @State private var showHistoryDialog: Bool = false
    @State private var exportStatus: String = ""

    public init(container: AppStateContainer, tab: QueryTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            QueryExecutionToolbar(
                container: container,
                tab: tab,
                workspace: workspace,
                onShowHistory: { showHistoryDialog = true }
            )

            if let notice = tab.notice {
                queryNoticeBanner(notice)
            }

            // Query Text Editor
            TextEditor(
                text: Binding(
                    get: { tab.text },
                    set: {
                        tab.text = $0
                        container.notifyUpdate()
                    }
                )
            )
            .padding(10)
            .background(Color.uiBackground)
            .frame(minHeight: 100, maxHeight: tab.pager != nil ? 180 : nil)

            resultsDividerBar

            QueryResultsPane(container: container, tab: tab, workspace: workspace)
        }
        .overlay {
            if showHistoryDialog {
                historyDialogOverlay
            }
        }
        .background(Color.uiBackground)
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
        HStack(spacing: 8) {
            ModernIcon(.warning, color: Color.uiWarning, size: 12)
            Text(notice)
                .font(.caption)
                .foregroundColor(Color.uiWarning)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.adaptive(light: Color.hex(0xFFFBEB), dark: Color.hex(0x271F0C)))
    }

    private var resultsDividerBar: some View {
        HStack(spacing: 8) {
            Text("RESULTS")
                .font(.caption2)
                .foregroundColor(Color.uiTextMuted)

            if let pager = tab.pager, !pager.columns.isEmpty {
                Text("•")
                    .font(.caption)
                    .foregroundColor(Color.uiTextFaint)

                HStack(spacing: 4) {
                    Text("\(pager.rowCount) rows")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                    Text("·")
                        .foregroundColor(Color.uiTextFaint)
                    ModernIcon(.history, color: Color.uiSuccess, size: 10)
                    Text("\(pager.elapsedMs) ms")
                        .font(.caption)
                        .foregroundColor(Color.uiSuccess)
                }
            }

            if !exportStatus.isEmpty {
                HStack(spacing: 4) {
                    ModernIcon(.checkmark, color: Color.uiSuccess, size: 9)
                    Text(exportStatus)
                        .font(.caption2)
                        .foregroundColor(Color.uiSuccess)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.adaptive(light: Color.hex(0xECFDF5), dark: Color.hex(0x064E3B)))
                .cornerRadius(4)
            }

            Spacer()

            if let pager = tab.pager, !pager.columns.isEmpty {
                let defaultName = tab.title.isEmpty ? "query_result" : tab.title.replacingOccurrences(of: " ", with: "_")

                Button {
                    Task {
                        let result = await ExportFileHelper.saveFile(
                            content: pager.exportCSV(),
                            defaultName: defaultName,
                            fileExtension: "csv",
                            saveAction: chooseFileSaveDestination
                        )
                        if !result.message.isEmpty {
                            exportStatus = result.message
                            container.notifyUpdate()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        ModernIcon(.export, color: Color.uiTextPrimary, size: 11)
                        Text("Export CSV")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        let result = await ExportFileHelper.saveFile(
                            content: pager.exportJSON(pretty: true),
                            defaultName: defaultName,
                            fileExtension: "json",
                            saveAction: chooseFileSaveDestination
                        )
                        if !result.message.isEmpty {
                            exportStatus = result.message
                            container.notifyUpdate()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        ModernIcon(.export, color: Color.uiTextPrimary, size: 11)
                        Text("Export JSON")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button {
                    ExportFileHelper.copyToClipboard(pager.exportCSV())
                    exportStatus = "Copied CSV"
                    container.notifyUpdate()
                } label: {
                    HStack(spacing: 4) {
                        ModernIcon(.copy, color: Color.uiTextMuted, size: 11)
                        Text("Copy CSV")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button {
                    ExportFileHelper.copyToClipboard(pager.exportJSON(pretty: true))
                    exportStatus = "Copied JSON"
                    container.notifyUpdate()
                } label: {
                    HStack(spacing: 4) {
                        ModernIcon(.copy, color: Color.uiTextMuted, size: 11)
                        Text("Copy JSON")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.uiSidebar)
    }
}

private struct QueryExecutionToolbar: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel
    let onShowHistory: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            runOrCancelButton

            if workspace.config.kind.isSQL {
                Button {
                    tab.format()
                    container.notifyUpdate()
                } label: {
                    Text("Format SQL")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.uiPanel)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }

            Button {
                onShowHistory()
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.history, color: Color.uiTextMuted, size: 12)
                    Text("History (\(tab.history.count))")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            if let db = tab.database ?? (workspace.config.database.isEmpty ? nil : workspace.config.database) {
                HStack(spacing: 5) {
                    ModernIcon(.database, color: Color.nodeDatabase, size: 11)
                    Text(db)
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                }
            }

            Spacer()

            queryStatusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.uiSidebar)
    }

    @ViewBuilder
    private var runOrCancelButton: some View {
        if tab.isRunning {
            Button {
                tab.cancel()
                container.notifyUpdate()
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.stop, color: Color.white, size: 10)
                    Text("Cancel")
                        .font(.caption)
                        .foregroundColor(Color.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiDanger)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Text("Executing query...")
                .font(.caption)
                .foregroundColor(Color.uiAccent)
        } else {
            Button {
                Task {
                    await tab.run()
                    container.notifyUpdate()
                }
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.play, color: Color.white, size: 10)
                    Text("Run (Ctrl+Enter)")
                        .font(.caption)
                        .foregroundColor(Color.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.uiAccent)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var queryStatusView: some View {
        switch tab.status {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 5) {
                ModernIcon(.refresh, color: Color.uiAccent, size: 11)
                Text("Running...")
                    .font(.caption)
                    .foregroundColor(Color.uiAccent)
            }
        case .finished:
            if let pager = tab.pager {
                let rowInfo = pager.rowsAffected != nil ? "\(pager.rowsAffected!) rows affected" : "\(pager.rowCount) rows"
                HStack(spacing: 5) {
                    ModernIcon(.checkmark, color: Color.uiSuccess, size: 10)
                    Text("Success · \(rowInfo) · \(pager.elapsedMs) ms")
                        .font(.caption)
                        .foregroundColor(Color.uiSuccess)
                }
            }
        case .failed(let err):
            HStack(spacing: 5) {
                ModernIcon(.warning, color: Color.uiDanger, size: 11)
                Text("Error: \(err)")
                    .font(.caption)
                    .foregroundColor(Color.uiDanger)
            }
        case .cancelled:
            Text("Query cancelled")
                .font(.caption)
                .foregroundColor(Color.uiTextMuted)
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
                            .foregroundColor(Color.uiTextMuted)
                        Spacer()
                        Button {
                            docMode = (docMode == .table ? .documents : .table)
                            container.notifyUpdate()
                        } label: {
                            HStack(spacing: 5) {
                                ModernIcon(docMode == .table ? .copy : .table, color: Color.uiTextMuted, size: 12)
                                Text(docMode == .table ? "Cards View" : "Table View")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.uiPanel)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.uiSidebar)

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
                                    tableTab: tab.id
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
        } else {
            VStack {
                Spacer()
                Text("Press 'Run' or press Ctrl+Enter to execute query")
                    .foregroundColor(Color.uiTextFaint)
                    .font(.body)
                Spacer()
            }
            .background(Color.uiBackground)
        }
    }

    private func resultGrid(pager: any GridDataSource) -> some View {
        ResultGrid(
            source: pager,
            onSelectCell: { rowIndex, colIndex in
                if colIndex < pager.columns.count,
                   let row = pager.row(at: rowIndex) {
                    let col = pager.columns[colIndex]
                    let val = colIndex < row.cells.count ? row.cells[colIndex] : Value.null
                    workspace.inspected = WorkspaceModel.InspectedCell(
                        column: col,
                        value: val,
                        row: rowIndex,
                        columnIndex: colIndex,
                        tableTab: tab.id
                    )
                    container.app.showInspector = true
                    container.notifyUpdate()
                }
            }
        )
    }
}

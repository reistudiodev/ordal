import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform query editor, execution toolbar, and results pane.
public struct QueryTabView: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let workspace: WorkspaceModel

    public init(container: AppStateContainer, tab: QueryTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Execution toolbar
            HStack(spacing: 12) {
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

                if workspace.config.kind.isSQL {
                    Button("Format SQL") {
                        tab.format()
                        container.notifyUpdate()
                    }
                }

                if let db = tab.database ?? (workspace.config.database.isEmpty ? nil : workspace.config.database) {
                    Text("Database: \(db)")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                }

                Spacer()

                // Status indicator
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color.adaptive(
                    light: Color(white: 0.95),
                    dark: Color(white: 0.18)
                )
            )

            // Warning notice (read-only, blocked)
            if let notice = tab.notice {
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

            // Split: SQL Editor on top, Results on bottom
            VStack(spacing: 0) {
                // SQL Editor
                TextEditor(text: Binding(get: { tab.text }, set: { tab.text = $0 }))
                    .frame(minHeight: 120, maxHeight: 240)
                    .padding(8)

                // Divider bar
                HStack {
                    Text("Results")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Color.adaptive(
                        light: Color(white: 0.9),
                        dark: Color(white: 0.2)
                    )
                )

                // Query Results
                if let pager = tab.pager {
                    if pager.hasDocuments {
                        DocumentListView(
                            source: pager,
                            onSelectField: { rowIndex, fieldName in
                                if let col = pager.columns.first,
                                   let row = pager.row(at: rowIndex) {
                                    let val = row.cells.first ?? Value.null
                                    workspace.inspected = WorkspaceModel.InspectedCell(column: col, value: val, row: rowIndex, columnIndex: 0, tableTab: nil)
                                    container.app.showInspector = true
                                    container.notifyUpdate()
                                }
                            }
                        )
                    } else {
                        ResultGrid(
                            source: pager,
                            onSelectCell: { rowIndex, colIndex in
                                if colIndex < pager.columns.count,
                                   let row = pager.row(at: rowIndex) {
                                    let col = pager.columns[colIndex]
                                    let val = colIndex < row.cells.count ? row.cells[colIndex] : Value.null
                                    workspace.inspected = WorkspaceModel.InspectedCell(column: col, value: val, row: rowIndex, columnIndex: colIndex, tableTab: nil)
                                    container.app.showInspector = true
                                    container.notifyUpdate()
                                }
                            },
                            onSortColumn: { col in
                                pager.toggleSort(column: col)
                                container.notifyUpdate()
                            }
                        )
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
        }
    }
}

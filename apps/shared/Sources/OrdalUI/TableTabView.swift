import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform Table Tab View with Data, Structure, and DDL inspection,
/// plus staged cell editing, review changes dialog, and MongoDB document support.
public struct TableTabView: View {
    let container: AppStateContainer
    let tab: TableTabModel
    let workspace: WorkspaceModel

    @State private var showReviewDialog: Bool = false

    public init(container: AppStateContainer, tab: TableTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Segment Header
            HStack(spacing: 8) {
                Button(tab.segment == .data ? "● Data" : "Data") {
                    tab.segment = .data
                    container.notifyUpdate()
                }
                Button(tab.segment == .structure ? "● Structure" : "Structure") {
                    tab.segment = .structure
                    Task {
                        await tab.loadStructure()
                        container.notifyUpdate()
                    }
                }
                Button(tab.segment == .ddl ? "● DDL" : "DDL") {
                    tab.segment = .ddl
                    Task {
                        await tab.loadStructure()
                        container.notifyUpdate()
                    }
                }

                Spacer()

                if !tab.pager.staged.isEmpty {
                    Button("Review Changes (\(tab.pager.staged.count))") {
                        showReviewDialog = true
                    }
                    .foregroundColor(Color.hex(0x856404))
                }

                Button("🔄 Refresh") {
                    Task {
                        await tab.pager.refresh()
                        await tab.loadStructure()
                        container.notifyUpdate()
                    }
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

            // Content according to selected segment
            switch tab.segment {
            case .data:
                dataView
            case .structure:
                structureView
            case .ddl:
                ddlView
            case .query:
                QueryTabView(container: container, tab: tab.query, workspace: workspace)
            }
        }
        .overlay {
            if showReviewDialog {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ReviewChangesDialog(
                            container: container,
                            pager: tab.pager,
                            config: workspace.config,
                            onDismiss: {
                                showReviewDialog = false
                                container.notifyUpdate()
                            }
                        )
                        Spacer()
                    }
                    Spacer()
                }
                .background(Color(white: 0.0, opacity: 0.5))
            }
        }
    }

    // MARK: - Data View
    private var dataView: some View {
        let pager = tab.pager
        return VStack(spacing: 0) {
            // Staged changes banner
            if !pager.staged.isEmpty {
                HStack(spacing: 12) {
                    Text("⚠️ \(pager.staged.count) staged change(s)")
                        .font(.caption)
                        .foregroundColor(Color.hex(0x856404))

                    Spacer()

                    Button("Review & Apply") {
                        showReviewDialog = true
                    }

                    Button("Discard All") {
                        pager.discardEdits()
                        container.notifyUpdate()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.from(pair: DataPalette.staged))
            }

            // Results grid or Document view
            if pager.hasDocuments {
                DocumentListView(
                    source: pager,
                    onSelectField: { rowIndex, fieldName in
                        if let colIndex = pager.columnIndex(of: fieldName),
                           let col = pager.columns.first(where: { $0.name == fieldName }),
                           let row = pager.row(at: rowIndex) {
                            let val = colIndex < row.cells.count ? row.cells[colIndex] : Value.null
                            workspace.inspected = WorkspaceModel.InspectedCell(column: col, value: val, row: rowIndex, columnIndex: colIndex, tableTab: tab.id)
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
                            workspace.inspected = WorkspaceModel.InspectedCell(column: col, value: val, row: rowIndex, columnIndex: colIndex, tableTab: tab.id)
                            container.app.showInspector = true
                            container.notifyUpdate()
                        }
                    },
                    onSortColumn: { column in
                        Task {
                            await pager.toggleSort(column: column)
                            container.notifyUpdate()
                        }
                    }
                )
            }

            // Pagination Footer Bar
            HStack(spacing: 12) {
                Button("◀ Previous") {
                    Task {
                        await pager.prev()
                        container.notifyUpdate()
                    }
                }

                Text(pager.rangeText)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))

                Button("Next ▶") {
                    Task {
                        await pager.next()
                        container.notifyUpdate()
                    }
                }

                Spacer()

                if pager.isLoading {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(Color.hex(0x007ACC))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Color.adaptive(
                    light: Color(white: 0.94),
                    dark: Color(white: 0.19)
                )
            )
        }
    }

    // MARK: - Structure View
    private var structureView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if let err = tab.structureError {
                    Text("Error loading structure: \(err)")
                        .font(.body)
                        .foregroundColor(Color.hex(0xDC3545))
                        .padding(16)
                } else if tab.structure.isEmpty {
                    Text("No columns or fields information loaded.")
                        .font(.body)
                        .foregroundColor(Color(white: 0.5))
                        .padding(16)
                } else {
                    HStack(spacing: 12) {
                        Text("Name").font(.caption).frame(minWidth: 160, alignment: .leading)
                        Text("Type / Details").font(.caption).frame(minWidth: 180, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.adaptive(light: Color(white: 0.88), dark: Color(white: 0.22)))

                    ForEach(tab.structure, id: \.name) { node in
                        HStack(spacing: 12) {
                            Text(node.name).font(.system(size: 13, design: .monospaced)).frame(minWidth: 160, alignment: .leading)
                            Text(node.detail ?? "-").font(.caption).foregroundColor(Color.hex(0x007ACC)).frame(minWidth: 180, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - DDL View
    private var ddlView: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 8) {
                if !tab.ddl.isEmpty {
                    Text(tab.ddl)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(16)
                } else {
                    Text("No DDL definition available for this object.")
                        .font(.body)
                        .foregroundColor(Color(white: 0.5))
                        .padding(16)
                }
            }
        }
    }
}

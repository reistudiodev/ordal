import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Modern native cross-platform Table Tab View with Data, Structure, Indexes, and DDL inspection.
public struct TableTabView: View {
    let container: AppStateContainer
    let tab: TableTabModel
    let workspace: WorkspaceModel

    @State private var showReviewDialog: Bool = false
    @State private var isRefreshing: Bool = false

    public init(container: AppStateContainer, tab: TableTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            segmentHeader
            contentSegment
        }
        .overlay {
            if showReviewDialog {
                reviewDialogOverlay
            }
        }
    }

    private var segmentHeader: some View {
        HStack(spacing: 4) {
            ForEach(tab.segments, id: \.id) { seg in
                let isSelected = tab.segment == seg
                let label: String = {
                    if seg == .indexes && !tab.indexes.isEmpty {
                        return "Indexes (\(tab.indexes.count))"
                    }
                    return seg.rawValue
                }()

                Button {
                    tab.segment = seg
                    if seg == .structure || seg == .indexes || seg == .ddl {
                        Task {
                            await tab.loadStructure()
                            container.notifyUpdate()
                        }
                    } else {
                        container.notifyUpdate()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isSelected {
                            Circle()
                                .foregroundColor(Color.uiAccent)
                                .frame(width: 5, height: 5)
                        }
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundColor(
                                isSelected
                                    ? Color.uiTextPrimary
                                    : Color.uiTextMuted
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isSelected
                            ? Color.uiHover
                            : Color.clear
                    )
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if !tab.pager.staged.isEmpty {
                Button {
                    showReviewDialog = true
                } label: {
                    HStack(spacing: 5) {
                        ModernIcon(.warning, color: Color.uiWarning, size: 12)
                        Text("Review Changes (\(tab.pager.staged.count))")
                            .font(.caption)
                            .foregroundColor(Color.uiWarning)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.uiHover)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    isRefreshing = true
                    container.notifyUpdate()
                    defer {
                        isRefreshing = false
                        container.notifyUpdate()
                    }
                    async let refreshTask: () = tab.pager.refresh()
                    async let structTask: () = tab.loadStructure()
                    _ = await (refreshTask, structTask)
                }
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.refresh, color: Color.uiTextMuted, size: 12)
                    Text(isRefreshing || tab.pager.isLoading ? "Refreshing…" : "Refresh")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.uiPanel)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing || tab.pager.isLoading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.uiSidebar)
    }

    @ViewBuilder
    private var contentSegment: some View {
        switch tab.segment {
        case .data:
            TableDataView(
                container: container,
                tab: tab,
                workspace: workspace,
                isRefreshing: isRefreshing,
                onShowReview: { showReviewDialog = true }
            )
        case .structure:
            TableStructureView(container: container, workspace: workspace, tab: tab)
        case .indexes:
            TableIndexesView(tab: tab)
        case .ddl:
            TableDDLView(tab: tab)
        case .query:
            QueryTabView(container: container, tab: tab.query, workspace: workspace)
        }
    }

    private var reviewDialogOverlay: some View {
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

private struct TableDataView: View {
    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination
    let container: AppStateContainer
    let tab: TableTabModel
    let workspace: WorkspaceModel
    var isRefreshing: Bool = false
    let onShowReview: () -> Void

    @State private var docMode: DocumentViewMode = .documents
    @State private var exportStatus: String = ""

    private var pager: TablePager { tab.pager }

    var body: some View {
        VStack(spacing: 0) {
            if !pager.staged.isEmpty {
                stagedBanner
            }

            if pager.sortIsSlow, let sort = pager.sort {
                slowSortBanner(column: sort.column)
            }

            if pager.hasDocuments {
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
                        .padding(.vertical, 4)
                        .background(Color.uiPanel)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.uiSidebar)
            }

            if pager.hasDocuments && docMode != .table {
                documentListView
            } else {
                resultGridView
            }

            paginationFooter
        }
    }

    private func slowSortBanner(column: String) -> some View {
        HStack(spacing: 8) {
            ModernIcon(.warning, color: Color.uiWarning, size: 13)
            Text("No index starts with “\(column)” - full table scan required.")
                .font(.caption)
                .foregroundColor(Color.uiWarning)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.adaptive(light: Color.hex(0xFFFBEB), dark: Color.hex(0x271F0C)))
    }

    private var stagedBanner: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ModernIcon(.edit, color: Color.uiWarning, size: 12)
                Text("\(pager.staged.count) staged change(s)")
                    .font(.caption)
                    .foregroundColor(Color.uiWarning)
            }

            Spacer()

            Button {
                onShowReview()
            } label: {
                Text("Review & Apply")
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            Button {
                pager.discardEdits()
                container.notifyUpdate()
            } label: {
                Text("Discard All")
                    .font(.caption)
                    .foregroundColor(Color.uiDanger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.from(pair: DataPalette.staged))
    }

    private var documentListView: some View {
        DocumentListView(
            source: pager,
            onSelectField: { rowIndex, fieldName in
                if let colIndex = pager.columnIndex(of: fieldName),
                   let col = pager.columns.first(where: { $0.name == fieldName }),
                   let row = pager.row(at: rowIndex) {
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

    private var resultGridView: some View {
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
            },
            onSortColumn: { column in
                Task {
                    await pager.toggleSort(column: column)
                    container.notifyUpdate()
                }
            }
        )
    }

    private var paginationFooter: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await pager.prev()
                    container.notifyUpdate()
                }
            } label: {
                HStack(spacing: 4) {
                    ModernIcon(.chevronLeft, color: Color.uiTextMuted, size: 9)
                    Text("Prev")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.uiPanel)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            Text(pager.rangeText)
                .font(.caption)
                .foregroundColor(Color.uiTextMuted)

            if let ms = pager.elapsedMs {
                HStack(spacing: 4) {
                    ModernIcon(.history, color: Color.uiTextFaint, size: 10)
                    Text("\(ms) ms")
                        .font(.caption)
                        .foregroundColor(Color.uiTextFaint)
                }
            }

            Button {
                Task {
                    await pager.next()
                    container.notifyUpdate()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                    ModernIcon(.chevronRight, color: Color.uiTextMuted, size: 9)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.uiPanel)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            if !exportStatus.isEmpty {
                HStack(spacing: 4) {
                    ModernIcon(.checkmark, color: Color.uiSuccess, size: 9)
                    Text(exportStatus)
                        .font(.caption2)
                        .foregroundColor(Color.uiSuccess)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.adaptive(light: Color.hex(0xECFDF5), dark: Color.hex(0x064E3B)))
                .cornerRadius(4)
            }

            Spacer()

            Button {
                Task {
                    let result = await ExportFileHelper.saveFile(
                        content: pager.exportCSV(),
                        defaultName: tab.title,
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
                .padding(.vertical, 4)
                .background(Color.uiPanel)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    let result = await ExportFileHelper.saveFile(
                        content: pager.exportJSON(pretty: true),
                        defaultName: tab.title,
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
                .padding(.vertical, 4)
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
                .padding(.vertical, 4)
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
                .padding(.vertical, 4)
                .background(Color.uiPanel)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            if pager.isLoading || isRefreshing {
                HStack(spacing: 5) {
                    ModernIcon(.refresh, color: Color.uiAccent, size: 10)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(Color.uiAccent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.uiSidebar)
    }
}

private struct TableStructureView: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let tab: TableTabModel

    var body: some View {
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let err = tab.structureError {
                        HStack(spacing: 8) {
                            ModernIcon(.warning, color: Color.uiDanger, size: 14)
                            Text("Error loading structure: \(err)")
                                .font(.body)
                                .foregroundColor(Color.uiDanger)
                        }
                        .padding(16)
                    } else if tab.structure.isEmpty {
                        Text("No columns or fields information loaded.")
                            .font(.body)
                            .foregroundColor(Color.uiTextMuted)
                            .padding(16)
                    } else {
                        structureHeader
                        ForEach(tab.structure, id: \.name) { node in
                            HStack(spacing: 12) {
                                Text(node.name)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(Color.uiTextPrimary)
                                    .frame(minWidth: 160, alignment: .leading)

                                Text(node.detail ?? "-")
                                    .font(.caption)
                                    .foregroundColor(Color.uiAccent)
                                    .frame(minWidth: 180, alignment: .leading)

                                if workspace.config.kind.isSQL && node.kind == .column {
                                    Button {
                                        let typeName = (node.detail ?? "").components(separatedBy: " · ").first ?? ""
                                        workspace.presentChangeColumnType(
                                            column: node.name,
                                            currentType: typeName,
                                            tablePath: tab.path,
                                            tableName: tab.title
                                        )
                                        container.notifyUpdate()
                                    } label: {
                                        HStack(spacing: 4) {
                                            ModernIcon(.edit, color: Color.uiAccent, size: 11)
                                            Text("Change Type")
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
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(12)

                Spacer()
            }
        }
        .background(Color.uiBackground)
    }

    private var structureHeader: some View {
        HStack(spacing: 12) {
            Text("COLUMN NAME").font(.caption).foregroundColor(Color.uiTextMuted).frame(minWidth: 160, alignment: .leading)
            Text("TYPE / DETAILS").font(.caption).foregroundColor(Color.uiTextMuted).frame(minWidth: 180, alignment: .leading)
            if workspace.config.kind.isSQL {
                Text("ACTION").font(.caption).foregroundColor(Color.uiTextMuted).frame(minWidth: 100, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.uiSidebar)
    }
}

private struct TableDDLView: View {
    let tab: TableTabModel

    var body: some View {
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if !tab.ddl.isEmpty {
                        Text(tab.ddl)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color.uiTextPrimary)
                            .padding(16)
                    } else {
                        Text("No DDL definition available for this object.")
                            .font(.body)
                            .foregroundColor(Color.uiTextMuted)
                            .padding(16)
                    }
                }
                Spacer()
            }
        }
        .background(Color.uiBackground)
    }
}

private struct TableIndexesView: View {
    let tab: TableTabModel

    var body: some View {
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    indexesHeader

                    if tab.indexes.isEmpty {
                        Text("No indexes defined for this collection or table.")
                            .font(.body)
                            .foregroundColor(Color.uiTextMuted)
                            .padding(16)
                    } else {
                        ForEach(tab.indexes, id: \.name) { index in
                            HStack(spacing: 12) {
                                Text(index.name)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(Color.uiTextPrimary)
                                    .frame(minWidth: 160, alignment: .leading)

                                Text(index.detail ?? "")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextMuted)
                                    .frame(minWidth: 240, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.uiBackground)
                        }
                    }
                }
                Spacer()
            }
        }
        .background(Color.uiBackground)
    }

    private var indexesHeader: some View {
        HStack(spacing: 12) {
            Text("INDEX NAME").font(.caption).foregroundColor(Color.uiTextMuted).frame(minWidth: 160, alignment: .leading)
            Text("KEYS & PROPERTIES").font(.caption).foregroundColor(Color.uiTextMuted).frame(minWidth: 240, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.uiSidebar)
    }
}

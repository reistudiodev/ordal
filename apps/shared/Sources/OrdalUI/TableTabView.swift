import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Native cross-platform Table Tab View with Data, Structure, and DDL inspection.
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
        HStack(spacing: 8) {
            ForEach(tab.segments, id: \.id) { seg in
                let isSelected = tab.segment == seg
                let label: String = {
                    if seg == .indexes && !tab.indexes.isEmpty {
                        return isSelected ? "● Indexes (\(tab.indexes.count))" : "Indexes (\(tab.indexes.count))"
                    }
                    return isSelected ? "● \(seg.rawValue)" : seg.rawValue
                }()
                Button(label) {
                    tab.segment = seg
                    if seg == .structure || seg == .indexes || seg == .ddl {
                        Task {
                            await tab.loadStructure()
                            container.notifyUpdate()
                        }
                    } else {
                        container.notifyUpdate()
                    }
                }
            }

            Spacer()

            if !tab.pager.staged.isEmpty {
                Button("Review Changes (\(tab.pager.staged.count))") {
                    showReviewDialog = true
                }
                .foregroundColor(Color.hex(0x856404))
            }

            Button(isRefreshing || tab.pager.isLoading ? "⏳ Refreshing…" : "🔄 Refresh") {
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
            }
            .disabled(isRefreshing || tab.pager.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.18)))
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
    let container: AppStateContainer
    let tab: TableTabModel
    let workspace: WorkspaceModel
    var isRefreshing: Bool = false
    let onShowReview: () -> Void

    @State private var docMode: DocumentViewMode = .documents

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
        HStack {
            Text("🐢 No index starts with “\(column)”, so every page scans the whole table.")
                .font(.caption)
                .foregroundColor(Color.hex(0x856404))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.adaptive(light: Color.hex(0xFFF3CD), dark: Color.hex(0x332701)))
    }

    private var stagedBanner: some View {
        HStack(spacing: 12) {
            Text("⚠️ \(pager.staged.count) staged change(s)")
                .font(.caption)
                .foregroundColor(Color.hex(0x856404))

            Spacer()

            Button("Review & Apply") {
                onShowReview()
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
            Button("◀ Previous") {
                Task {
                    await pager.prev()
                    container.notifyUpdate()
                }
            }

            Text(pager.rangeText)
                .font(.caption)
                .foregroundColor(Color(white: 0.5))

            if let ms = pager.elapsedMs {
                Text("⚡ \(ms) ms")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.6))
            }

            Button("Next ▶") {
                Task {
                    await pager.next()
                    container.notifyUpdate()
                }
            }

            Spacer()

            Button("📋 CSV") {
                #if os(macOS)
                AppKit.NSPasteboard.general.clearContents()
                AppKit.NSPasteboard.general.setString(pager.exportCSV(), forType: .string)
                #endif
            }

            Button("📋 JSON") {
                #if os(macOS)
                AppKit.NSPasteboard.general.clearContents()
                AppKit.NSPasteboard.general.setString(pager.exportJSON(pretty: true), forType: .string)
                #endif
            }

            if pager.isLoading || isRefreshing {
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(Color.hex(0x007ACC))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.19)))
    }
}

private struct TableStructureView: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let tab: TableTabModel

    var body: some View {
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
                    structureHeader
                    ForEach(tab.structure, id: \.name) { node in
                        HStack(spacing: 12) {
                            Text(node.name)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minWidth: 160, alignment: .leading)
                            Text(node.detail ?? "-")
                                .font(.caption)
                                .foregroundColor(Color.hex(0x007ACC))
                                .frame(minWidth: 180, alignment: .leading)
                            if workspace.config.kind.isSQL && node.kind == .column {
                                Button("✏️ Change Type") {
                                    let typeName = (node.detail ?? "").components(separatedBy: " · ").first ?? ""
                                    workspace.presentChangeColumnType(
                                        column: node.name,
                                        currentType: typeName,
                                        tablePath: tab.path,
                                        tableName: tab.title
                                    )
                                    container.notifyUpdate()
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(12)
        }
    }

    private var structureHeader: some View {
        HStack(spacing: 12) {
            Text("Name").font(.caption).frame(minWidth: 160, alignment: .leading)
            Text("Type / Details").font(.caption).frame(minWidth: 180, alignment: .leading)
            if workspace.config.kind.isSQL {
                Text("Action").font(.caption).frame(minWidth: 100, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.adaptive(light: Color(white: 0.88), dark: Color(white: 0.22)))
    }
}

private struct TableDDLView: View {
    let tab: TableTabModel

    var body: some View {
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

private struct TableIndexesView: View {
    let tab: TableTabModel

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                indexesHeader

                if tab.indexes.isEmpty {
                    Text("No indexes defined for this collection or table.")
                        .font(.body)
                        .foregroundColor(Color(white: 0.5))
                        .padding(16)
                } else {
                    ForEach(tab.indexes, id: \.name) { index in
                        HStack(spacing: 12) {
                            Text(index.name)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(minWidth: 160, alignment: .leading)

                            Text(index.detail ?? "")
                                .font(.caption)
                                .foregroundColor(Color(white: 0.6))
                                .frame(minWidth: 240, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.adaptive(light: Color(white: 0.98), dark: Color(white: 0.16)))
                    }
                }
            }
        }
    }

    private var indexesHeader: some View {
        HStack(spacing: 12) {
            Text("Index Name").font(.caption).frame(minWidth: 160, alignment: .leading)
            Text("Keys & Properties").font(.caption).frame(minWidth: 240, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.adaptive(light: Color(white: 0.88), dark: Color(white: 0.22)))
    }
}

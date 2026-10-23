import AppKit
import OrdalKit
import SwiftUI

/// Data first; Structure, DDL and a table-scoped Query as segments.
struct TableTabView: View {
    @Bindable var tab: TableTabModel
    let workspace: WorkspaceModel
    @Environment(AppState.self) private var app
    @State private var reviewing = false
    @State private var isReloading = false
    @AppStorage("mongoResultView") private var docMode: DocumentViewMode = .documents

    private var showsDocuments: Bool { tab.pager.hasDocuments && docMode != .table }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Picker("View", selection: $tab.segment) {
                    ForEach(tab.segments) { seg in
                        if seg == .indexes && !tab.indexes.isEmpty {
                            Text("Indexes (\(tab.indexes.count))").tag(seg)
                        } else {
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab.segment == .data, tab.pager.hasDocuments {
                    DocumentModePicker(mode: $docMode)
                }
                Spacer()
                if tab.segment == .data {
                    Menu {
                        Button {
                            ExportHelper.saveFile(content: tab.pager.exportCSV(), defaultName: tab.title, fileExtension: "csv")
                        } label: {
                            Label("Export as CSV…", systemImage: "tablecells")
                        }
                        Button {
                            ExportHelper.saveFile(content: tab.pager.exportJSON(pretty: true), defaultName: tab.title, fileExtension: "json")
                        } label: {
                            Label("Export as JSON…", systemImage: "curlybraces")
                        }
                        Divider()
                        Button {
                            ExportHelper.copy(text: tab.pager.exportCSV())
                        } label: {
                            Label("Copy CSV to Clipboard", systemImage: "doc.on.doc")
                        }
                        Button {
                            ExportHelper.copy(text: tab.pager.exportJSON(pretty: true))
                        } label: {
                            Label("Copy JSON to Clipboard", systemImage: "doc.on.doc.fill")
                        }
                        Divider()
                        Button {
                            workspace.presentExport(
                                name: tab.title,
                                path: tab.path,
                                kind: tab.kind == .collection ? .collection : .table
                            )
                        } label: {
                            Label("Export Options (Structure / Backup)…", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export current page data as CSV or JSON")
                }
                if tab.segment != .query {
                    Button {
                        Task {
                            isReloading = true
                            defer { isReloading = false }
                            async let refreshTask: () = tab.pager.refresh()
                            async let structTask: () = tab.loadStructure()
                            _ = await (refreshTask, structTask)
                        }
                    } label: {
                        if isReloading || tab.pager.isLoading {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Reloading…")
                            }
                        } else {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isReloading || tab.pager.isLoading)
                    .help("Reload data and structure")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.hairline + 2)
            Divider()

            switch tab.segment {
            case .data: data
            case .structure: structure.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .indexes: indexesView.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ddl: ddl.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .query: QueryTabView(tab: tab.query, workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $reviewing) {
            ReviewChangesSheet(pager: tab.pager, config: workspace.config) { reviewing = false }
        }
    }

    // MARK: Data

    @ViewBuilder
    private var data: some View {
        let pager = tab.pager
        let version = pager.version
        VStack(spacing: 0) {
            if !pager.staged.isEmpty {
                ChangesBar(count: pager.staged.count, review: { reviewing = true }, discard: { pager.discardEdits() })
            }
            if pager.sortIsSlow, let sort = pager.sort {
                Label("No index starts with “\(sort.column)”, so every page scans the whole table. On large tables this is slow.",
                      systemImage: "tortoise")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.hairline)
                    .background(.orange.opacity(0.12))
            }
            if let error = pager.error, pager.page == nil {
                ContentUnavailableView("Could not load data", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if pager.page == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsDocuments {
                DocumentList(
                    count: pager.rowCount, mode: docMode, document: pager.document(at:), version: version,
                    staged: { row in stagedFields(row) },
                    onSelectField: { row, field in
                        if let col = pager.columnIndex(of: field) {
                            inspect(row: row, col: col)
                            app.showInspector = true
                        }
                    }
                )
            } else {
                ResultGridView(
                    source: pager, version: version,
                    onSelectCell: { row, col in inspect(row: row, col: col) },
                    onActivateCell: { _, _ in app.showInspector = true },
                    onSortColumn: { column in Task { await pager.toggleSort(column: column) } }
                )
            }
            Divider()
            PaginationBar(pager: pager, isReloading: isReloading)
        }
        .overlay(alignment: .top) {
            if isReloading || pager.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isReloading ? "Reloading table data…" : "Loading data…")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                .padding(.top, 10)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
                .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isReloading || pager.isLoading)
    }

    /// Top-level fields of a row with staged edits, and their new values.
    private func stagedFields(_ row: Int) -> [String: Value] {
        guard !tab.pager.staged.isEmpty, let cells = tab.pager.row(at: row)?.cells else { return [:] }
        var out: [String: Value] = [:]
        for (i, col) in tab.pager.columns.enumerated() where i < cells.count && tab.pager.isStaged(row: row, column: i) {
            out[col.name] = cells[i]
        }
        return out
    }

    private func inspect(row: Int, col: Int) {
        guard let r = tab.pager.row(at: row), col < r.cells.count else { return }
        workspace.inspected = .init(column: tab.pager.columns[col], value: r.cells[col], row: row, columnIndex: col, tableTab: tab.id)
    }

    // MARK: Structure and DDL

    @ViewBuilder
    private var structure: some View {
        if let error = tab.structureError {
            ContentUnavailableView("Could not load structure", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.config.kind.isSQL {
            Table(tab.structure.map(StructureRow.init)) {
                TableColumn("Name") { Text($0.name).font(.body.monospaced()) }
                TableColumn("Kind") { Text($0.kind) }.width(min: 60, ideal: 80, max: 120)
                TableColumn("Details") { Text($0.detail).font(.body.monospaced()).foregroundStyle(.secondary) }
                TableColumn("Action") { row in
                    if row.kind == "column" {
                        Button {
                            let typeName = row.detail.components(separatedBy: " · ").first ?? ""
                            workspace.presentChangeColumnType(
                                column: row.name,
                                currentType: typeName,
                                tablePath: tab.path,
                                tableName: tab.title
                            )
                        } label: {
                            Label("Change Type…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .width(min: 120, ideal: 140, max: 180)
            }
        } else {
            Table(tab.structure.map(StructureRow.init)) {
                TableColumn("Name") { Text($0.name).font(.body.monospaced()) }
                TableColumn("Kind") { Text($0.kind) }.width(min: 60, ideal: 80, max: 120)
                TableColumn("Details") { Text($0.detail).font(.body.monospaced()).foregroundStyle(.secondary) }
            }
        }
    }

    private var ddl: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ScrollView {
                Text(tab.ddl)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
            }
            HStack {
                Text("Rebuilt from the catalog: columns, NOT NULL and the primary key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.ddl, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(Space.s)
        }
    }
}

/// |< < Page 3 of ~10,000 > >|, the row range, page size and an exact count.
private struct PaginationBar: View {
    let pager: TablePager
    var isReloading: Bool = false
    @State private var jump = ""

    var body: some View {
        HStack(spacing: Space.s) {
            Group {
                Button { Task { await pager.first() } } label: { Image(systemName: "chevron.left.to.line") }
                    .help("First page")
                    .disabled(!pager.hasPrev)
                Button { Task { await pager.prev() } } label: { Image(systemName: "chevron.left") }
                    .help("Previous page")
                    .disabled(!pager.hasPrev)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Text(pageText).monospacedDigit().frame(minWidth: 120)
                Button { Task { await pager.next() } } label: { Image(systemName: "chevron.right") }
                    .help("Next page")
                    .disabled(!pager.hasNext)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button { Task { await pager.last() } } label: { Image(systemName: "chevron.right.to.line") }
                    .help("Last page")
                    .disabled(!pager.hasNext || (!pager.usesKeyset && pager.pageCount == nil))
            }
            .buttonStyle(.borderless)

            TextField("Page", text: $jump, prompt: Text("Go to"))
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let n = Int(jump) { Task { await pager.goTo(page: n) } }
                    jump = ""
                }
                .help(pager.usesKeyset
                      ? "Jumps use an offset: far pages of a huge table take longer. First/Next/Previous/Last stay fast."
                      : "This relation has no key, so every page uses an offset.")

            Divider().frame(height: 14)
            if pager.isLoading || isReloading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 14)
            } else if let ms = pager.elapsedMs {
                Label("\(ms) ms", systemImage: "bolt.fill")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Page fetch duration: \(ms) ms")
                Divider().frame(height: 14)
            }
            Text(rowsText).foregroundStyle(.secondary).monospacedDigit()
            if pager.count?.exact == false {
                Button(pager.isCounting ? "Counting…" : "Count") { Task { await pager.refreshCount(exact: true) } }
                    .disabled(pager.isCounting)
                    .help("Count every row exactly (up to a minute on very large tables)")
            }
            Spacer()
            if !pager.usesKeyset, pager.page != nil {
                Label("Offset paging", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(pager.sort != nil && pager.meta?.paging == .keyset
                          ? "Sorted by a field, this collection pages with skip."
                          : "No primary key: pages use OFFSET, which slows down far into big tables.")
            }
            Picker("Rows per page", selection: Binding(get: { pager.pageSize }, set: { size in Task { await pager.setPageSize(size) } })) {
                ForEach(TablePager.pageSizes, id: \.self) { Text("\($0) rows").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Space.s)
        .frame(height: 30)
    }

    private var pageText: String {
        guard let pages = pager.pageCount else { return "Page \(pager.pageNumber)" }
        let approx = pager.count?.exact == false ? "~" : ""
        return "Page \(pager.pageNumber.formatted()) of \(approx)\(pages.formatted())"
    }

    private var rowsText: String {
        guard let count = pager.count else { return pager.rangeText }
        return "\(pager.rangeText) of \(count.exact ? "" : "~")\(count.count.formatted()) rows"
    }
}

/// Shown while there are staged edits.
private struct ChangesBar: View {
    let count: Int
    let review: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(Color(nsColor: DataColors.date))
            Text("\(count) unsaved \(count == 1 ? "change" : "changes")").font(.callout.weight(.medium))
            Spacer()
            Button("Discard", role: .destructive, action: discard)
            Button("Review Changes…", action: review)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        .controlSize(.small)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.hairline + 2)
        .background(Color(nsColor: DataColors.staged))
    }
}

private struct StructureRow: Identifiable {
    let name: String
    let kind: String
    let detail: String
    var id: String { name + kind }

    init(_ node: BrowseNode) {
        name = node.name
        kind = "\(node.kind)"
        detail = node.detail ?? ""
    }
}

extension TableTabView {
    @ViewBuilder
    fileprivate var indexesView: some View {
        if let error = tab.structureError {
            ContentUnavailableView("Could not load indexes", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab.indexes.isEmpty {
            ContentUnavailableView {
                Label("No Indexes", systemImage: "text.magnifyingglass")
            } description: {
                Text("This collection or table has no secondary indexes.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("\(tab.indexes.count) \(tab.indexes.count == 1 ? "Index" : "Indexes") on \(tab.title)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.headline)
                    Spacer()
                    Text("MongoDB Compass Index View")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                Divider()

                List(tab.indexes, id: \.name) { index in
                    IndexCardView(node: index)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct IndexCardView: View {
    let node: BrowseNode
    @State private var copied = false

    private var details: [String] {
        guard let d = node.detail, !d.isEmpty else { return [] }
        return d.components(separatedBy: " · ")
    }

    private var keySpec: String {
        details.first ?? ""
    }

    private var propertyBadges: [String] {
        Array(details.dropFirst())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "number.square.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)

                Text(node.name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))

                if node.name == "_id_" {
                    Pill(text: "DEFAULT", color: .secondary)
                }

                ForEach(propertyBadges, id: \.self) { badge in
                    let lower = badge.lowercased()
                    if lower.contains("unique") {
                        Pill(text: "UNIQUE", color: .purple)
                    } else if lower.contains("sparse") {
                        Pill(text: "SPARSE", color: .teal)
                    } else if lower.contains("expire") || lower.contains("ttl") {
                        Pill(text: badge.uppercased(), color: .orange)
                    } else {
                        Pill(text: badge.uppercased(), color: .secondary)
                    }
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(keySpec.isEmpty ? node.name : keySpec, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .foregroundStyle(.green)
                    } else {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if !keySpec.isEmpty {
                HStack(spacing: 6) {
                    Text("Fields:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(keySpec)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

import AppKit
import DBClientKit
import SwiftUI

/// Data first; Structure, DDL and a table-scoped Query as segments.
struct TableTabView: View {
    @Bindable var tab: TableTabModel
    let workspace: WorkspaceModel
    @Environment(AppState.self) private var app
    @State private var reviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Picker("View", selection: $tab.segment) {
                    ForEach(tab.segments) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab.segment != .query {
                    Button {
                        Task {
                            await tab.pager.refresh()
                            await tab.loadStructure()
                        }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload data and structure")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.hairline + 2)
            Divider()

            switch tab.segment {
            case .data: data
            case .structure: structure
            case .ddl: ddl
            case .query: QueryTabView(tab: tab.query, workspace: workspace)
            }
        }
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
            } else {
                ResultGridView(
                    source: pager, version: version,
                    onSelectCell: { row, col in inspect(row: row, col: col) },
                    onActivateCell: { _, _ in app.showInspector = true },
                    onSortColumn: { column in Task { await pager.toggleSort(column: column) } }
                )
                .overlay(alignment: .top) {
                    if pager.isLoading { ProgressView().controlSize(.small).padding(Space.s) }
                }
            }
            Divider()
            PaginationBar(pager: pager)
        }
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

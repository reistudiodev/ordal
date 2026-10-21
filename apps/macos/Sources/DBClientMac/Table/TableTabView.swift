import AppKit
import DBClientKit
import SwiftUI

/// Data first; Structure and DDL as segments instead of separate windows.
struct TableTabView: View {
    @Bindable var tab: TableTabModel
    let workspace: WorkspaceModel

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
                Button {
                    Task {
                        await tab.pager.reload()
                        await tab.loadStructure()
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload data and structure")
                Button("Query") {
                    if let node = workspace.browser.node(at: tab.path) {
                        workspace.newQueryTab(text: workspace.starterQuery(for: node), database: workspace.database(for: tab.path))
                    }
                }
                .help("Open a query tab for this table")
            }
            .controlSize(.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.hairline + 2)
            Divider()

            switch tab.segment {
            case .data: data
            case .structure: structure
            case .ddl: ddl
            }
        }
    }

    @ViewBuilder
    private var data: some View {
        let pager = tab.pager
        let version = pager.version
        if let error = pager.error, pager.columns.isEmpty {
            ContentUnavailableView("Could not load data", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if pager.columns.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultGridView(source: pager, version: version) { column, value, row in
                workspace.inspected = .init(column: column, value: value, row: row)
            }
        }
    }

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

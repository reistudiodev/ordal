import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform Schema Relations & ERD Viewer.
public struct SchemaDiagramTabView: View {
    let container: AppStateContainer
    let tab: SchemaTabModel
    let workspace: WorkspaceModel

    @State private var searchQuery: String = ""
    @State private var didStart = false

    public init(container: AppStateContainer, tab: SchemaTabModel, workspace: WorkspaceModel) {
        self.container = container
        self.tab = tab
        self.workspace = workspace
    }

    private var filteredTables: [GraphTable] {
        let tables = tab.visibleTables
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tables
        }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
        }
        .onAppear {
            if !didStart {
                didStart = true
                loadSchema()
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(tab.title)
                .font(.headline)

            if let graph = tab.graph {
                Text("\(graph.tables.count) tables · \(graph.relations.count) relations")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            TextField(
                "Filter tables...",
                text: Binding(
                    get: { searchQuery },
                    set: {
                        searchQuery = $0
                        container.notifyUpdate()
                    }
                )
            )
            .frame(maxWidth: 180)

            Button(tab.focusOnly ? "● Focus Only" : "Focus Only") {
                tab.focusOnly.toggle()
                container.notifyUpdate()
            }

            Button {
                tab.resetLayout()
                container.notifyUpdate()
            } label: {
                Text("Tidy Up")
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.uiPanel)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)

            Button {
                loadSchema()
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.refresh, color: Color.uiTextMuted, size: 11)
                    Text("Reload")
                        .font(.caption)
                        .foregroundColor(Color.uiTextPrimary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.uiPanel)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.uiSidebar)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let err = tab.error {
            Text("Error loading schema: \(err)")
                .font(.body)
                .foregroundColor(Color.hex(0xDC3545))
                .padding(16)
        } else if tab.isLoading {
            VStack {
                Spacer()
                Text("Loading schema graph...")
                    .font(.body)
                    .foregroundColor(Color.hex(0x007ACC))
                Spacer()
            }
        } else {
            diagramLayout
        }
    }

    private var diagramLayout: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                tablesSection
                relationsSection
            }
            .padding(20)
        }
    }

    private var tablesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tables & Columns")
                .font(.headline)
                .foregroundColor(Color(white: 0.6))

            HStack(alignment: .top, spacing: 16) {
                ForEach(filteredTables, id: \.name) { table in
                    let isSelected = tab.selected == table.name
                    TableCardView(
                        table: table,
                        schemaTab: tab,
                        isSelected: isSelected,
                        onSelect: {
                            tab.selected = isSelected ? nil : table.name
                            container.notifyUpdate()
                        },
                        onOpenTable: {
                            if let node = workspace.browser.loadedNodes.first(where: { $0.name == table.name }) {
                                workspace.openTable(node)
                                container.notifyUpdate()
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var relationsSection: some View {
        if let relations = tab.graph?.relations, !relations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Foreign Key Relationships")
                    .font(.headline)
                    .foregroundColor(Color(white: 0.6))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(relations, id: \.fromTable) { rel in
                        RelationRowView(rel: rel)
                    }
                }
                .padding(12)
                .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.16)))
                .cornerRadius(6)
            }
        }
    }

    private func loadSchema() {
        Task {
            await tab.start()
            container.notifyUpdate()
        }
    }
}

private struct RelationRowView: View {
    let rel: Relation

    var body: some View {
        HStack(spacing: 8) {
            Text(rel.fromTable)
                .font(.headline)
                .foregroundColor(Color.hex(0x007ACC))

            Text("(\(rel.fromColumns.joined(separator: ", ")))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.5))

            ModernIcon(.chevronRight, size: 10)
                .foregroundColor(Color(white: 0.5))

            Text(rel.toTable)
                .font(.headline)
                .foregroundColor(Color.hex(0x28A745))

            Text("(\(rel.toColumns.joined(separator: ", ")))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private struct TableCardView: View {
    let table: GraphTable
    let schemaTab: SchemaTabModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenTable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            columnsList
            referencesFooter
        }
        .frame(minWidth: 200, maxWidth: 260)
        .background(Color.adaptive(light: Color(white: 0.98), dark: Color(white: 0.19)))
        .cornerRadius(6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(table.name) {
                onSelect()
            }
            .font(.headline)
            .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.9))

            Spacer()

            Button("Open") {
                onOpenTable()
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.adaptive(light: Color.hex(0xCCE5FF), dark: Color.hex(0x113355))
                : Color.adaptive(light: Color(white: 0.88), dark: Color(white: 0.22))
        )
    }

    private var columnsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(table.columns, id: \.name) { col in
                let isFk = schemaTab.isForeignKey(table: table.name, column: col.name)
                HStack(spacing: 6) {
                    if col.isKey {
                        ModernIcon(.key, color: Color.uiWarning, size: 10)
                    } else if isFk {
                        ModernIcon(.column, color: Color.uiAccent, size: 10)
                    } else {
                        Spacer().frame(width: 10)
                    }

                    Text(col.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(col.isKey ? Color.uiAccent : Color.uiTextPrimary)

                    Spacer()

                    Text(col.typeName)
                        .font(.caption)
                        .foregroundColor(Color(white: 0.45))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var referencesFooter: some View {
        let refs = schemaTab.references(of: table.name)
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("References:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.4))
                Text(refs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(Color.hex(0x28A745))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.17)))
        }
    }
}

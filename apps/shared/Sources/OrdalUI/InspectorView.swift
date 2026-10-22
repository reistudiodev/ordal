import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform Cell Inspector & Inline Cell Editor.
public struct InspectorView: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let onDismiss: () -> Void

    public init(container: AppStateContainer, workspace: WorkspaceModel, onDismiss: @escaping () -> Void) {
        self.container = container
        self.workspace = workspace
        self.onDismiss = onDismiss
    }

    private var activeTableTab: TableTabModel? {
        guard let cell = workspace.inspected,
              let id = cell.tableTab,
              case .table(let t)? = workspace.tabs.first(where: { $0.id == id })
        else { return nil }
        return t
    }

    private var columnMeta: ColumnMeta? {
        guard let cell = workspace.inspected, let tab = activeTableTab else { return nil }
        return tab.pager.columnMeta(cell.column.name)
    }

    private var canEdit: Bool {
        guard let tab = activeTableTab, tab.pager.canEdit, let meta = columnMeta else { return false }
        return meta.editable && !meta.isKey
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Cell Inspector")
                    .font(.headline)

                Spacer()

                Button("✕") {
                    workspace.inspected = nil
                    container.notifyUpdate()
                    onDismiss()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.adaptive(light: Color(white: 0.92), dark: Color(white: 0.18)))

            if let cell = workspace.inspected {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Field details
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cell.column.name)
                                .font(.headline)
                            Text("\(cell.column.typeName.isEmpty ? "\(cell.column.kind)" : cell.column.typeName) · Row \(cell.row + 1)")
                                .font(.caption)
                                .foregroundColor(Color(white: 0.5))
                        }

                        // Editor or Value display
                        if canEdit, let meta = columnMeta, let tab = activeTableTab {
                            CellEditorView(cell: cell, meta: meta, tab: tab, container: container)
                        } else {
                            // Read-only text
                            VStack(alignment: .leading, spacing: 4) {
                                if let meta = columnMeta, meta.isKey {
                                    Text("🔑 Primary Key (read-only)")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.5))
                                } else {
                                    Text("🔒 Read-only")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.5))
                                }

                                Text("Full Value:")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.5))

                                Text(cell.value.inspectorText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(cell.value.isNull ? Color(white: 0.5) : Color(white: 0.9))
                                    .padding(8)
                                    .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.14)))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No cell selected")
                        .font(.body)
                        .foregroundColor(Color(white: 0.5))
                    Text("Click on any row cell in a table or query result to inspect or edit it.")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.4))
                        .padding(.horizontal, 16)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 320)
        .background(Color.adaptive(light: Color(white: 0.97), dark: Color(white: 0.16)))
    }
}

private struct CellEditorView: View {
    let cell: WorkspaceModel.InspectedCell
    let meta: ColumnMeta
    let tab: TableTabModel
    let container: AppStateContainer

    @State private var editText: String
    @State private var isNullValue: Bool

    init(cell: WorkspaceModel.InspectedCell, meta: ColumnMeta, tab: TableTabModel, container: AppStateContainer) {
        self.cell = cell
        self.meta = meta
        self.tab = tab
        self.container = container
        _editText = State(wrappedValue: cell.value.isNull ? "" : CellValueParser.editText(cell.value))
        _isNullValue = State(wrappedValue: cell.value.isNull)
    }

    private var isStaged: Bool {
        tab.pager.isStaged(row: cell.row, column: cell.columnIndex)
    }

    private var parsedValue: Result<Value, CellValueParser.ParseError> {
        if isNullValue { return .success(.null) }
        return CellValueParser.parse(editText, for: meta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStaged {
                Text("⚠️ Changed (Pending Review)")
                    .font(.caption)
                    .foregroundColor(Color.hex(0x856404))
                    .padding(4)
                    .background(Color.from(pair: DataPalette.staged))
                    .cornerRadius(4)
            }

            Text("Edit Value:")
                .font(.caption)
                .foregroundColor(Color(white: 0.5))

            if isNullValue {
                HStack {
                    Text("NULL")
                        .font(.body)
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    Button("Set Value") {
                        isNullValue = false
                        editText = meta.kind == .bool ? "false" : ""
                    }
                }
                .padding(8)
                .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.15)))
            } else {
                if meta.kind == .bool {
                    HStack(spacing: 8) {
                        Button(editText == "true" ? "● True" : "True") {
                            editText = "true"
                        }
                        Button(editText == "false" ? "● False" : "False") {
                            editText = "false"
                        }
                    }
                } else {
                    TextField(
                        meta.name,
                        text: Binding(
                            get: { editText },
                            set: { editText = $0 }
                        )
                    )

                    // Helpers
                    HStack(spacing: 6) {
                        if meta.kind == .timestamp || meta.kind == .timestampTz {
                            Button("Now") {
                                let f = DateFormatter()
                                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                                editText = f.string(from: Date())
                            }
                        } else if meta.kind == .date {
                            Button("Today") {
                                let f = DateFormatter()
                                f.dateFormat = "yyyy-MM-dd"
                                editText = f.string(from: Date())
                            }
                        } else if meta.kind == .uuid {
                            Button("New UUID") {
                                editText = UUID().uuidString.lowercased()
                            }
                        }
                    }
                }
            }

            if meta.nullable && !isNullValue {
                Button("Set to NULL") {
                    isNullValue = true
                }
            }

            // Parse error if any
            if case .failure(let err) = parsedValue {
                Text(err.message)
                    .font(.caption)
                    .foregroundColor(Color.hex(0xDC3545))
            }

            // Action buttons
            HStack(spacing: 8) {
                if isStaged {
                    Button("Revert") {
                        tab.pager.revert(row: cell.row, column: cell.columnIndex)
                        editText = CellValueParser.editText(cell.value)
                        isNullValue = cell.value.isNull
                        container.notifyUpdate()
                    }
                }

                Spacer()

                Button("Stage Change") {
                    if case .success(let newVal) = parsedValue {
                        tab.pager.stage(row: cell.row, column: cell.columnIndex, value: newVal)
                        container.notifyUpdate()
                    }
                }
            }
        }
    }
}

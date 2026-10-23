import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Native cross-platform Cell Inspector & Inline Cell Editor.
/// Redesigned with type badges, JSON formatters, quick copy, and clear staging status.
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
            .background(Color.adaptive(light: Color(white: 0.90), dark: Color(white: 0.18)))

            if let cell = workspace.inspected {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Field details card
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(cell.column.name)
                                    .font(.headline)

                                Spacer()

                                Button("📋 Copy") {
                                    #if os(macOS)
                                    AppKit.NSPasteboard.general.clearContents()
                                    AppKit.NSPasteboard.general.setString(cell.value.inspectorText, forType: .string)
                                    #endif
                                }
                            }

                            HStack(spacing: 6) {
                                Text(cell.column.typeName.isEmpty ? "\(cell.column.kind)".uppercased() : cell.column.typeName.uppercased())
                                    .font(.caption)
                                    .foregroundColor(Color.hex(0x007ACC))

                                if workspace.config.kind.isSQL, let tab = activeTableTab {
                                    Button("✏️ Change") {
                                        workspace.presentChangeColumnType(
                                            column: cell.column.name,
                                            currentType: cell.column.typeName,
                                            tablePath: tab.path,
                                            tableName: tab.title
                                        )
                                        container.notifyUpdate()
                                    }
                                }

                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.5))

                                Text("Row \(cell.row + 1)")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.5))

                                if let meta = columnMeta {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.5))

                                    Text(meta.nullable ? "Nullable" : "Not Null")
                                        .font(.caption)
                                        .foregroundColor(meta.nullable ? Color(white: 0.5) : Color.hex(0x28A745))
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.14)))
                        .cornerRadius(6)

                        // Editor or Value display
                        if canEdit, let meta = columnMeta, let tab = activeTableTab {
                            CellEditorView(cell: cell, meta: meta, tab: tab, container: container)
                        } else {
                            // Read-only text
                            VStack(alignment: .leading, spacing: 6) {
                                if let meta = columnMeta, meta.isKey {
                                    Text("🔑 Primary Key (read-only)")
                                        .font(.caption)
                                        .foregroundColor(Color.hex(0xD39E00))
                                } else {
                                    Text("🔒 Read-only")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.5))
                                }

                                Text(cell.value.inspectorText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(cell.value.isNull ? Color(white: 0.5) : Color(white: 0.9))
                                    .padding(10)
                                    .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.12)))
                                    .cornerRadius(6)
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

    private var isJSON: Bool {
        meta.kind == .json || editText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStaged {
                HStack {
                    Text("⚠️ Changed (Pending Review)")
                        .font(.caption)
                        .foregroundColor(Color.hex(0x856404))
                    Spacer()
                    Button("Revert") {
                        tab.pager.revert(row: cell.row, column: cell.columnIndex)
                        editText = CellValueParser.editText(cell.value)
                        isNullValue = cell.value.isNull
                        container.notifyUpdate()
                    }
                }
                .padding(6)
                .background(Color.from(pair: DataPalette.staged))
                .cornerRadius(4)
            }

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
                .cornerRadius(4)
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
                    if isJSON {
                        HStack {
                            Button("✨ Format JSON") {
                                if let pretty = prettyJSON(editText) { editText = pretty }
                            }
                            Button("🗜 Compact") {
                                if let compact = compactJSON(editText) { editText = compact }
                            }
                            Spacer()
                        }
                    }

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

    private func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private func compactJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }
}

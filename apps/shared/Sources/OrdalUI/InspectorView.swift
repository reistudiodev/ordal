import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Modern native cross-platform Cell Inspector sidebar panel.
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
              case .table(let tab) = workspace.tabs.first(where: { $0.id == cell.tableTab })
        else { return nil }
        return tab
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
                Text("CELL INSPECTOR")
                    .font(.caption2)
                    .foregroundColor(Color.uiTextMuted)

                Spacer()

                Button {
                    workspace.inspected = nil
                    container.notifyUpdate()
                    onDismiss()
                } label: {
                    ModernIcon(.close, color: Color.uiTextMuted, size: 10, strokeWidth: 1.6)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.uiSidebar)

            if let cell = workspace.inspected {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Field details card
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(cell.column.name)
                                    .font(.headline)
                                    .foregroundColor(Color.uiTextPrimary)

                                Spacer()

                                Button {
                                    #if os(macOS)
                                    AppKit.NSPasteboard.general.clearContents()
                                    AppKit.NSPasteboard.general.setString(cell.value.inspectorText, forType: .string)
                                    #endif
                                } label: {
                                    HStack(spacing: 4) {
                                        ModernIcon(.copy, color: Color.uiTextMuted, size: 11)
                                        Text("Copy")
                                            .font(.caption)
                                            .foregroundColor(Color.uiTextPrimary)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 6) {
                                Text(cell.column.typeName.isEmpty ? "\(cell.column.kind)".uppercased() : cell.column.typeName.uppercased())
                                    .font(.caption)
                                    .foregroundColor(Color.uiAccent)

                                if workspace.config.kind.isSQL, let tab = activeTableTab {
                                    Button {
                                        workspace.presentChangeColumnType(
                                            column: cell.column.name,
                                            currentType: cell.column.typeName,
                                            tablePath: tab.path,
                                            tableName: tab.title
                                        )
                                        container.notifyUpdate()
                                    } label: {
                                        HStack(spacing: 4) {
                                            ModernIcon(.edit, color: Color.uiAccent, size: 10)
                                            Text("Change")
                                                .font(.caption)
                                                .foregroundColor(Color.uiTextPrimary)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.uiPanel)
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextFaint)

                                Text("Row \(cell.row + 1)")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextMuted)

                                if let meta = columnMeta {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(Color.uiTextFaint)

                                    Text(meta.nullable ? "Nullable" : "Not Null")
                                        .font(.caption)
                                        .foregroundColor(meta.nullable ? Color.uiTextMuted : Color.uiSuccess)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.uiPanel)
                        .cornerRadius(6)

                        // Editor or Value display
                        if canEdit, let meta = columnMeta, let tab = activeTableTab {
                            CellEditorView(cell: cell, meta: meta, tab: tab, container: container)
                        } else {
                            // Read-only text
                            VStack(alignment: .leading, spacing: 6) {
                                if let meta = columnMeta, meta.isKey {
                                    HStack(spacing: 5) {
                                        ModernIcon(.key, color: Color.uiWarning, size: 11)
                                        Text("Primary Key (read-only)")
                                            .font(.caption)
                                            .foregroundColor(Color.uiWarning)
                                    }
                                } else {
                                    Text("Read-only")
                                        .font(.caption)
                                        .foregroundColor(Color.uiTextMuted)
                                }

                                Text(cell.value.inspectorText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color.uiTextPrimary)
                            }
                            .padding(10)
                            .background(Color.uiPanel)
                            .cornerRadius(6)
                        }

                        // Raw representation
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RAW REPRESENTATION")
                                .font(.caption2)
                                .foregroundColor(Color.uiTextMuted)

                            Text(String(describing: cell.value))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color.uiTextFaint)
                        }
                        .padding(10)
                        .background(Color.uiPanel)
                        .cornerRadius(6)
                    }
                    .padding(12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Click any cell in the table or result grid to inspect its value.")
                        .font(.body)
                        .foregroundColor(Color.uiTextMuted)
                        .padding(20)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 260, maxWidth: 360)
        .background(Color.uiSidebar)
    }
}

private struct CellEditorView: View {
    let cell: WorkspaceModel.InspectedCell
    let meta: ColumnMeta
    let tab: TableTabModel
    let container: AppStateContainer

    @State private var editText: String = ""
    @State private var isNullValue: Bool = false

    public init(
        cell: WorkspaceModel.InspectedCell,
        meta: ColumnMeta,
        tab: TableTabModel,
        container: AppStateContainer
    ) {
        self.cell = cell
        self.meta = meta
        self.tab = tab
        self.container = container
        self._editText = State(wrappedValue: CellValueParser.editText(cell.value))
        self._isNullValue = State(wrappedValue: cell.value.isNull)
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
                HStack(spacing: 6) {
                    ModernIcon(.warning, color: Color.uiWarning, size: 12)
                    Text("Changed (Pending Review)")
                        .font(.caption)
                        .foregroundColor(Color.uiWarning)
                    Spacer()
                    Button {
                        tab.pager.revert(row: cell.row, column: cell.columnIndex)
                        editText = CellValueParser.editText(cell.value)
                        isNullValue = cell.value.isNull
                        container.notifyUpdate()
                    } label: {
                        Text("Revert")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.uiPanel)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(Color.from(pair: DataPalette.staged))
                .cornerRadius(4)
            }

            if isNullValue {
                HStack {
                    Text("NULL")
                        .font(.body)
                        .foregroundColor(Color.uiTextMuted)
                    Spacer()
                    Button {
                        isNullValue = false
                        editText = meta.kind == .bool ? "false" : ""
                    } label: {
                        Text("Set Value")
                            .font(.caption)
                            .foregroundColor(Color.uiTextPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.uiPanel)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.uiPanel)
                .cornerRadius(4)
            } else {
                if meta.kind == .bool {
                    HStack(spacing: 8) {
                        Button {
                            editText = "true"
                        } label: {
                            Text(editText == "true" ? "● True" : "True")
                                .font(.caption)
                                .foregroundColor(Color.uiTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(editText == "true" ? Color.uiHover : Color.uiPanel)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)

                        Button {
                            editText = "false"
                        } label: {
                            Text(editText == "false" ? "● False" : "False")
                                .font(.caption)
                                .foregroundColor(Color.uiTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(editText == "false" ? Color.uiHover : Color.uiPanel)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    if isJSON {
                        HStack(spacing: 6) {
                            Button {
                                if let pretty = prettyJSON(editText) { editText = pretty }
                            } label: {
                                Text("Format JSON")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)

                            Button {
                                if let compact = compactJSON(editText) { editText = compact }
                            } label: {
                                Text("Compact")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
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
                            Button {
                                let f = DateFormatter()
                                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                                editText = f.string(from: Date())
                            } label: {
                                Text("Now")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        } else if meta.kind == .date {
                            Button {
                                let f = DateFormatter()
                                f.dateFormat = "yyyy-MM-dd"
                                editText = f.string(from: Date())
                            } label: {
                                Text("Today")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        } else if meta.kind == .uuid {
                            Button {
                                editText = UUID().uuidString.lowercased()
                            } label: {
                                Text("New UUID")
                                    .font(.caption)
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if meta.nullable && !isNullValue {
                Button {
                    isNullValue = true
                } label: {
                    Text("Set to NULL")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.uiPanel)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            // Parse error if any
            if case .failure(let err) = parsedValue {
                HStack(spacing: 5) {
                    ModernIcon(.warning, color: Color.uiDanger, size: 10)
                    Text(err.message)
                        .font(.caption)
                        .foregroundColor(Color.uiDanger)
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                Spacer()

                Button {
                    if case .success(let newVal) = parsedValue {
                        tab.pager.stage(row: cell.row, column: cell.columnIndex, value: newVal)
                        container.notifyUpdate()
                    }
                } label: {
                    Text("Stage Change")
                        .font(.caption)
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.uiAccent)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
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

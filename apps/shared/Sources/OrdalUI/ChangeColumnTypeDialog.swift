import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI
#if os(macOS)
import AppKit
#endif

/// Native cross-platform modal dialog for altering a table column's data type.
/// Supports PostgreSQL, MySQL, and SQLite, with categorized types, quick selection buttons,
/// custom type entry, live SQL preview, and execution.
public struct ChangeColumnTypeDialog: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let target: ColumnTypeTarget
    let onDismiss: @MainActor @Sendable () -> Void

    @State private var selectedCategoryId: String = "text"
    @State private var newType: String = ""
    @State private var isApplying = false
    @State private var errorMessage: String = ""

    public init(
        container: AppStateContainer,
        workspace: WorkspaceModel,
        target: ColumnTypeTarget,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.container = container
        self.workspace = workspace
        self.target = target
        self.onDismiss = onDismiss
    }

    private var engine: DatabaseKind { workspace.config.kind }
    private var categories: [SQLTypeCategory] { SQLTypeCatalog.categories(for: engine) }

    private var currentCategory: SQLTypeCategory? {
        categories.first { $0.id == selectedCategoryId } ?? categories.first
    }

    private var canApply: Bool {
        let trimmed = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(target.currentType) != .orderedSame
    }

    private var previewSQL: String {
        let trimmed = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-- Enter or select a data type" }
        do {
            let meta: TableMeta? = {
                for tab in workspace.tabs {
                    if case .table(let t) = tab, t.path == target.tablePath {
                        return t.pager.meta
                    }
                }
                return nil
            }()
            let (sql, _) = try SchemaManager.alterColumnTypeSQL(
                engine: engine,
                path: target.tablePath,
                column: target.column,
                newType: trimmed,
                tableMeta: meta
            )
            return sql
        } catch {
            return "-- Preview unavailable: \(error.localizedDescription)"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ModernIcon(.refresh, color: Color.uiAccent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change Column Data Type")
                        .font(.title3)
                        .foregroundColor(Color.uiTextPrimary)
                    Text("Column: \(target.column) on \(target.tableName) · Current: \(target.currentType.isEmpty ? "unknown" : target.currentType)")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    ModernIcon(.close, color: Color.uiTextMuted, size: 11)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Category Bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Category:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))

                HStack(spacing: 6) {
                    ForEach(categories, id: \.id) { cat in
                        let isSelected = selectedCategoryId == cat.id
                        Button(cat.name) {
                            selectedCategoryId = cat.id
                            container.notifyUpdate()
                        }
                        .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.7))
                    }
                }
            }

            // Quick Type Selection Buttons
            if let cat = currentCategory {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Select Types:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.7))

                    HStack(spacing: 6) {
                        ForEach(cat.types, id: \.self) { t in
                            let isSelected = newType.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(t) == .orderedSame
                            Button(t) {
                                newType = t
                                container.notifyUpdate()
                            }
                            .foregroundColor(isSelected ? Color.hex(0x28A745) : Color(white: 0.8))
                        }
                    }
                }
            }

            // Editable Target Type Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Target Type (Customizable):")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))

                TextField(target.currentType.isEmpty ? "VARCHAR(255)" : target.currentType, text: $newType)

                Text("Supports all SQL types with precision/length (e.g. VARCHAR(100), DECIMAL(10,2)).")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            // SQL Preview Box
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Generated SQL Statement:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.7))
                    Spacer()
                    #if os(macOS)
                    Button {
                        AppKit.NSPasteboard.general.clearContents()
                        AppKit.NSPasteboard.general.setString(previewSQL, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            ModernIcon(.copy, color: Color.uiTextMuted, size: 10)
                            Text("Copy")
                                .font(.caption)
                                .foregroundColor(Color.uiTextPrimary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.uiPanel)
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    #endif
                }

                ScrollView(.vertical) {
                    Text(previewSQL)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                }
                .frame(maxHeight: 70)
                .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.16)))
            }

            if isApplying {
                HStack(spacing: 8) {
                    ModernIcon(.refresh, color: Color.uiAccent, size: 12)
                    Text("Altering column type to \(newType)...")
                        .font(.caption)
                        .foregroundColor(Color.uiAccent)
                }
            } else if !errorMessage.isEmpty {
                HStack(spacing: 6) {
                    ModernIcon(.warning, color: Color.uiDanger, size: 12)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(Color.uiDanger)
                }
            }

            Divider()

            // Actions
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.uiPanel)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task {
                        await performChange()
                    }
                } label: {
                    Text("Change Type")
                        .font(.body)
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(canApply ? Color.uiAccent : Color(white: 0.3))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(!canApply || isApplying)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear {
            if let cat = categories.first {
                selectedCategoryId = cat.id
            }
            if !target.currentType.isEmpty {
                newType = target.currentType
            } else if let first = categories.first?.types.first {
                newType = first
            }
        }
    }

    private func performChange() async {
        let trimmed = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isApplying = true
        errorMessage = ""
        container.notifyUpdate()

        do {
            try await workspace.changeColumnType(target: target, newType: trimmed)
            isApplying = false
            container.notifyUpdate()
            onDismiss()
        } catch {
            isApplying = false
            errorMessage = error.localizedDescription
            container.notifyUpdate()
        }
    }
}

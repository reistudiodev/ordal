import AppKit
import OrdalKit
import SwiftUI

/// Modern, clean modal sheet for altering a table column's data type.
/// Provides categorized SQL types (text, int, decimal, bool, datetime, json, etc.),
/// quick selection pills, custom type entry, live SQL preview, and execution.
struct ChangeColumnTypeSheet: View {
    @Bindable var workspace: WorkspaceModel
    let target: ColumnTypeTarget
    let onDismiss: () -> Void

    @State private var selectedCategoryId: String = "text"
    @State private var newType: String = ""
    @State private var isApplying = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: "pencil.and.ruler.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Change Column Data Type")
                        .font(.headline.weight(.semibold))

                    HStack(spacing: 4) {
                        Text("Column:")
                            .foregroundStyle(.secondary)
                        Text(target.column)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        Text("· Table:")
                            .foregroundStyle(.secondary)
                        Text(target.tableName)
                            .font(.caption.weight(.medium))
                        Text("· Current:")
                            .foregroundStyle(.secondary)
                        Text(target.currentType.isEmpty ? "unknown" : target.currentType)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .font(.caption)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }

            Divider()

            // Category Selector
            HStack(spacing: Space.s) {
                Text("Category:")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedCategoryId) {
                    ForEach(categories) { cat in
                        Text(cat.name).tag(cat.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 210)

                Spacer()
            }

            // Quick Selection Pills
            if let cat = currentCategory {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Suggested Presets (\(cat.name))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Click to select")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(cat.types, id: \.self) { typeOption in
                                typePill(typeOption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Editable Target Type Input
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Target SQL Type")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if canApply {
                        Label("Ready to apply", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }

                TextField("e.g. VARCHAR(255), INTEGER, TIMESTAMPTZ", text: $newType)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFieldFocused)
                    .onSubmit {
                        if canApply && !isApplying {
                            Task { await performChange() }
                        }
                    }

                Text("Type any valid SQL type expression, or customize length/precision (e.g. VARCHAR(100), DECIMAL(10,2)).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Live SQL Preview
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("SQL Statement Preview", systemImage: "terminal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(previewSQL, forType: .string)
                    } label: {
                        Label("Copy SQL", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                }

                ScrollView(.vertical) {
                    Text(previewSQL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 52, maxHeight: 72)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .cornerRadius(6)
            }

            if let error = errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Altering column \(target.column) to \(newType)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Footer actions
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await performChange() }
                } label: {
                    if isApplying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Altering…")
                        }
                    } else {
                        Text("Change Type")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || isApplying)
            }
        }
        .padding(22)
        .frame(width: 530)
        .onAppear {
            let cat = categories.first
            selectedCategoryId = cat?.id ?? "text"
            if !target.currentType.isEmpty {
                newType = target.currentType
            } else if let first = cat?.types.first {
                newType = first
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private func typePill(_ typeOption: String) -> some View {
        let isSelected = newType.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(typeOption) == .orderedSame
        Button {
            newType = typeOption
        } label: {
            Text(typeOption)
                .font(.system(.caption, design: .monospaced).weight(isSelected ? .bold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
    }

    private func performChange() async {
        let trimmed = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isApplying = true
        errorMessage = nil

        do {
            try await workspace.changeColumnType(target: target, newType: trimmed)
            isApplying = false
            onDismiss()
        } catch {
            isApplying = false
            errorMessage = error.localizedDescription
        }
    }
}

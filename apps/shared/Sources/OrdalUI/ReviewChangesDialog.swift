import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

public struct PendingChangeItem: Identifiable {
    public let id: String
    public let keyText: String
    public let column: String
    public let oldText: String
    public let newText: String

    public init(change: TablePager.PendingChange) {
        let key = change.cell.key.map(\.cellText).joined(separator: ":")
        self.id = "\(key):\(change.cell.column)"
        self.keyText = change.cell.key.map(\.cellText).joined(separator: ", ")
        self.column = change.cell.column
        self.oldText = change.old.cellText
        self.newText = change.new.cellText
    }
}

/// Dialog for reviewing staged cell edits, previewing generated SQL/Commands,
/// and safely committing changes in a single transaction.
public struct ReviewChangesDialog: View {
    let container: AppStateContainer
    let pager: TablePager
    let config: ConnectionConfig
    let onDismiss: () -> Void

    @State private var statements: [String] = []
    @State private var previewError: String?
    @State private var applyError: String?
    @State private var isApplying = false
    @State private var confirmationInput = ""
    @State private var didLoadStatements = false

    public init(
        container: AppStateContainer,
        pager: TablePager,
        config: ConnectionConfig,
        onDismiss: @escaping () -> Void
    ) {
        self.container = container
        self.pager = pager
        self.config = config
        self.onDismiss = onDismiss
    }

    private var isProd: Bool { config.environment == .prod }
    private var expectedName: String { config.database.isEmpty ? config.name : config.database }
    private var canApply: Bool {
        if isApplying || previewError != nil { return false }
        if isProd && confirmationInput != expectedName { return false }
        return true
    }

    private var changeItems: [PendingChangeItem] {
        pager.pendingChanges.map { PendingChangeItem(change: $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            changesListView
            statementsSection
            if isProd {
                productionGuardView
            }
            if let applyError {
                Text("Error applying changes: \(applyError)")
                    .font(.caption)
                    .foregroundColor(Color.hex(0xDC3545))
            }
            actionsFooterView
        }
        .padding(16)
        .frame(minWidth: 560, maxWidth: 680)
        .background(Color.adaptive(light: Color(white: 1.0), dark: Color(white: 0.18)))
        .cornerRadius(8)
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            ModernIcon(isProd ? .warning : .edit, color: isProd ? Color.uiDanger : Color.uiWarning, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Review \(pager.staged.count) Pending Change(s)")
                    .font(.headline)
                    .foregroundColor(Color.uiTextPrimary)
                Text("\(pager.path.last ?? "") · \(config.name)\(isProd ? " · Production" : "")")
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
        .padding(.bottom, 4)
    }

    private var changesListView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modified Fields:")
                .font(.caption)
                .foregroundColor(Color(white: 0.5))

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("Row Key").font(.caption).frame(minWidth: 100, alignment: .leading)
                        Text("Column").font(.caption).frame(minWidth: 120, alignment: .leading)
                        Text("Before").font(.caption).frame(minWidth: 140, alignment: .leading)
                        Text("After").font(.caption).frame(minWidth: 140, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.adaptive(light: Color(white: 0.88), dark: Color(white: 0.22)))

                    ForEach(changeItems, id: \.id) { item in
                        PendingChangeRowView(item: item)
                    }
                }
            }
            .frame(maxHeight: 160)
            .background(Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.16)))
            .cornerRadius(4)
        }
    }

    private var statementsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(config.kind == .mongoDb ? "Generated Commands:" : "Generated SQL Statements:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                if !didLoadStatements {
                    Button("Preview Statements") {
                        loadPreview()
                    }
                }
            }

            StatementPreviewBoxView(
                statements: statements,
                previewError: previewError,
                didLoadStatements: didLoadStatements
            )
        }
    }

    private var productionGuardView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ModernIcon(.warning, color: Color.uiDanger, size: 12)
                Text("Production Safeguard: Type **\(expectedName)** to confirm:")
                    .font(.caption)
                    .foregroundColor(Color.uiDanger)
            }

            TextField(
                "Database or connection name",
                text: Binding(
                    get: { confirmationInput },
                    set: { confirmationInput = $0 }
                )
            )
        }
    }

    private var actionsFooterView: some View {
        HStack {
            Button("Discard All") {
                pager.discardEdits()
                container.notifyUpdate()
                onDismiss()
            }

            Spacer()

            Button("Cancel") {
                onDismiss()
            }

            Button(isApplying ? "Applying..." : "Apply Changes") {
                applyChanges()
            }
            .disabled(!canApply)
        }
        .padding(.top, 8)
    }

    private func loadPreview() {
        didLoadStatements = true
        Task {
            do {
                let stmts = try await pager.previewStatements()
                self.statements = stmts
                self.previewError = nil
            } catch {
                self.previewError = describe(error)
            }
            container.notifyUpdate()
        }
    }

    private func applyChanges() {
        isApplying = true
        applyError = nil
        Task {
            do {
                try await pager.applyEdits()
                isApplying = false
                container.notifyUpdate()
                onDismiss()
            } catch {
                isApplying = false
                applyError = describe(error)
                container.notifyUpdate()
            }
        }
    }
}

private struct PendingChangeRowView: View {
    let item: PendingChangeItem

    var body: some View {
        HStack(spacing: 8) {
            Text(item.keyText.isEmpty ? "-" : item.keyText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 100, alignment: .leading)
            Text(item.column)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 120, alignment: .leading)
            Text(item.oldText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.5))
                .frame(minWidth: 140, alignment: .leading)
            Text(item.newText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.hex(0x28A745))
                .frame(minWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct StatementPreviewBoxView: View {
    let statements: [String]
    let previewError: String?
    let didLoadStatements: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading) {
                let previewText: String = {
                    if let err = previewError {
                        return "Error generating preview: \(err)"
                    }
                    if statements.isEmpty {
                        return didLoadStatements ? "-- No statements generated" : "-- Click 'Preview Statements' to inspect SQL"
                    }
                    return statements.joined(separator: ";\n") + ";"
                }()

                Text(previewText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(previewError != nil ? Color.hex(0xDC3545) : Color(white: 0.8))
                    .padding(8)
            }
        }
        .frame(minHeight: 80, maxHeight: 140)
        .background(Color.adaptive(light: Color(white: 0.92), dark: Color(white: 0.12)))
        .cornerRadius(4)
    }
}

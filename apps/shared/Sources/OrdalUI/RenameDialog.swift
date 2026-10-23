import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern rename dialog for tables, views, schemas, and databases.
public struct RenameDialog: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let target: RenameTarget
    let onDismiss: () -> Void

    @State private var newName: String = ""
    @State private var isRenaming: Bool = false
    @State private var errorMessage: String = ""

    public init(
        container: AppStateContainer,
        workspace: WorkspaceModel,
        target: RenameTarget,
        onDismiss: @escaping () -> Void
    ) {
        self.container = container
        self.workspace = workspace
        self.target = target
        self.onDismiss = onDismiss
        self._newName = State(wrappedValue: target.name)
    }

    private var canRename: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != target.name
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ModernIcon(iconType(for: target.kind), color: iconColor(for: target.kind), size: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename \(target.kindText)")
                        .font(.title3)
                        .foregroundColor(Color.uiTextPrimary)
                    Text("Current: \(target.name) · \(workspace.config.kind.label)")
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

            // Input
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter new name:")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)

                TextField(target.name, text: $newName)
            }

            if isRenaming {
                HStack(spacing: 8) {
                    ModernIcon(.refresh, color: Color.uiAccent, size: 12)
                    Text("Renaming \(target.name)...")
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
                        await performRename()
                    }
                } label: {
                    Text("Rename")
                        .font(.body)
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(canRename ? Color.uiAccent : Color(white: 0.3))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(!canRename || isRenaming)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .background(Color.uiBackground)
        .cornerRadius(8)
    }

    private func iconType(for kind: RenameTarget.Kind) -> IconType {
        switch kind {
        case .table: .table
        case .view: .view
        case .collection: .table
        case .database: .database
        case .schema: .schema
        }
    }

    private func iconColor(for kind: RenameTarget.Kind) -> Color {
        switch kind {
        case .table: Color.nodeTable
        case .view: Color.nodeView
        case .collection: Color.nodeTable
        case .database: Color.nodeDatabase
        case .schema: Color.nodeFolder
        }
    }

    private func performRename() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != target.name else { return }

        isRenaming = true
        errorMessage = ""
        container.notifyUpdate()

        do {
            try await workspace.renameNode(target: target, to: trimmed)
            isRenaming = false
            container.notifyUpdate()
            onDismiss()
        } catch {
            isRenaming = false
            errorMessage = error.localizedDescription
            container.notifyUpdate()
        }
    }
}

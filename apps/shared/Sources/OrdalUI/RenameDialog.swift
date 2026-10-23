import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform modal dialog for renaming tables, collections, schemas, and databases.
public struct RenameDialog: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let target: RenameTarget
    let onDismiss: @MainActor @Sendable () -> Void

    @State private var newName: String = ""
    @State private var isRenaming = false
    @State private var errorMessage: String = ""

    public init(
        container: AppStateContainer,
        workspace: WorkspaceModel,
        target: RenameTarget,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.container = container
        self.workspace = workspace
        self.target = target
        self.onDismiss = onDismiss
    }

    private var canSubmit: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != target.name
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Text(headerIcon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename \(target.kindText)")
                        .font(.title3)
                    Text("Current: \(target.name) · \(workspace.config.kind.label)")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.6))
                }
                Spacer()
                Button("✕") {
                    onDismiss()
                }
            }

            Divider()

            // Input
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter new name:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))

                TextField(target.name, text: $newName)
            }

            if isRenaming {
                HStack(spacing: 8) {
                    Text("⏳")
                    Text("Renaming \(target.name)...")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.6))
                }
            } else if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Color.hex(0xDC3545))
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    onDismiss()
                }

                Spacer()

                Button("Rename") {
                    Task {
                        await performRename()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private var headerIcon: String {
        switch target.kind {
        case .table: "📄"
        case .view: "👁️"
        case .collection: "📚"
        case .database: "🗄️"
        case .schema: "📁"
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

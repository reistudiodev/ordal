import AppKit
import OrdalKit
import SwiftUI

/// Clean, modern macOS modal sheet for renaming tables, views, collections, schemas, and databases.
struct RenameDialogSheet: View {
    @Bindable var workspace: WorkspaceModel
    let target: RenameTarget
    let onDismiss: () -> Void

    @State private var newName: String = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // Header
            HStack(spacing: Space.m) {
                Image(systemName: iconName)
                    .font(.system(size: 26))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename \(target.kindText)")
                        .font(.title3.weight(.semibold))
                    Text("Current name: \(target.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Input
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Enter a new name for this \(target.kindText.lowercased()):")
                    .font(.subheadline)

                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($isFocused)
                    .onSubmit {
                        if canSubmit { Task { await performRename() } }
                    }

                Text("Database: \(workspace.config.kind.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                .padding(.vertical, Space.hairline)
            }

            if isRenaming {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Renaming \(target.name) to \(newName)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    Task { await performRename() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isRenaming)
            }
        }
        .padding(Space.l)
        .frame(width: 420, height: 260)
        .onAppear {
            newName = target.name
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private var canSubmit: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != target.name
    }

    private var iconName: String {
        switch target.kind {
        case .table: "tablecells"
        case .view: "eye"
        case .collection: "shippingbox"
        case .database: "cylinder.split.1x2"
        case .schema: "folder"
        }
    }

    private func performRename() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != target.name else { return }

        isRenaming = true
        errorMessage = nil

        do {
            try await workspace.renameNode(target: target, to: trimmed)
            isRenaming = false
            onDismiss()
        } catch {
            isRenaming = false
            errorMessage = error.localizedDescription
        }
    }
}

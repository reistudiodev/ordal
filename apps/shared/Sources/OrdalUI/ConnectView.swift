import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform dialog for creating or editing database connections.
public struct ConnectView: View {
    let container: AppStateContainer
    let form: ConnectionFormModel

    private var app: AppState { container.app }

    public init(container: AppStateContainer, form: ConnectionFormModel) {
        self.container = container
        self.form = form
    }

    public var body: some View {
        VStack(spacing: 16) {
            ConnectHeaderView(
                isEditing: form.isEditing,
                onCancel: {
                    app.form = nil
                    container.notifyUpdate()
                }
            )

            EngineSelectorView(
                selectedKind: form.kind,
                onSelectKind: { kind in
                    form.kind = kind
                    container.notifyUpdate()
                }
            )

            ScrollView(.vertical) {
                ConnectFormFieldsView(form: form, container: container)
                    .padding(.vertical, 8)
            }

            ConnectFooterView(
                form: form,
                app: app,
                container: container
            )
            .padding(.top, 8)
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 600)
    }
}

private struct ConnectHeaderView: View {
    let isEditing: Bool
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        HStack {
            Text(isEditing ? "Edit Connection" : "New Connection")
                .font(.title2)
            Spacer()
            Button("Cancel", action: onCancel)
        }
    }
}

private struct EngineSelectorView: View {
    let selectedKind: DatabaseKind
    let onSelectKind: (DatabaseKind) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DatabaseKind.all, id: \.self) { kind in
                let isSelected = selectedKind == kind
                Button(isSelected ? "● \(kind.label)" : kind.label) {
                    onSelectKind(kind)
                }
            }
        }
    }
}

private struct ConnectFormFieldsView: View {
    let form: ConnectionFormModel
    let container: AppStateContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // URL Shortcut
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection URL (optional shortcut):")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                TextField("e.g. postgres://user:password@localhost:5432/db", text: bind(\.url))
            }

            // Host & Port (or SQLite file path)
            if form.kind == .sqlite {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Database file path:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                    TextField("/path/to/database.db or :memory:", text: bind(\.host))
                }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host:")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        TextField("localhost", text: bind(\.host))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port:")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        TextField("5432", text: bind(\.port))
                            .frame(width: 80)
                    }
                }
            }

            // Database Name
            if form.kind != .sqlite {
                VStack(alignment: .leading, spacing: 4) {
                    Text(form.kind == .redis ? "Database index (0-15):" : "Database:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                    TextField(form.kind == .redis ? "0" : "my_database", text: bind(\.database))
                }
            }

            // Credentials
            if form.kind != .sqlite && form.kind != .redis {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Username:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                    TextField("postgres", text: bind(\.username))
                }
            }

            if form.usesPassword {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                    TextField("••••••••", text: bind(\.password))
                }
            }

            // Name & Environment
            VStack(alignment: .leading, spacing: 4) {
                Text("Display Name:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                TextField(form.suggestedName.isEmpty ? "Display Name" : form.suggestedName, text: bind(\.name))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                HStack(spacing: 8) {
                    ForEach(EnvironmentTag.all, id: \.self) { env in
                        Button(env.label) {
                            form.environment = env
                            container.notifyUpdate()
                        }
                    }
                }
            }

            // Read-only Flag
            HStack(spacing: 8) {
                Button(form.readOnly ? "☑ Read-only connection" : "☐ Read-only connection") {
                    form.readOnly.toggle()
                    container.notifyUpdate()
                }
            }
        }
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<ConnectionFormModel, String>) -> Binding<String> {
        Binding(
            get: { form[keyPath: keyPath] },
            set: { form[keyPath: keyPath] = $0 }
        )
    }
}

private struct ConnectFooterView: View {
    let form: ConnectionFormModel
    let app: AppState
    let container: AppStateContainer

    var body: some View {
        HStack(spacing: 12) {
            Button("Test Connection") {
                Task {
                    if let manager = app.manager {
                        await form.runTest(using: manager)
                    }
                    container.notifyUpdate()
                }
            }

            statusIndicator

            Button(form.isEditing ? "Save Changes" : "Save & Connect") {
                Task {
                    await app.saveForm(connect: true)
                    container.notifyUpdate()
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch form.test {
        case .idle:
            Spacer()
        case .testing:
            Text("Testing...")
                .font(.caption)
                .foregroundColor(Color(white: 0.6))
            Spacer()
        case .succeeded(let version):
            Text("Connected: \(version)")
                .font(.caption)
                .foregroundColor(Color.hex(0x28A745))
            Spacer()
        case .failed(let message):
            Text("Error: \(message)")
                .font(.caption)
                .foregroundColor(Color.hex(0xDC3545))
            Spacer()
        }
    }
}

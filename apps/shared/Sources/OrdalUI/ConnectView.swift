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
            // Header
            HStack {
                Text(form.isEditing ? "Edit Connection" : "New Connection")
                    .font(.title2)
                Spacer()
                Button("Cancel") {
                    app.form = nil
                    container.notifyUpdate()
                }
            }

            // Engine selector
            HStack(spacing: 8) {
                ForEach(DatabaseKind.all, id: \.self) { kind in
                    let isSelected = form.kind == kind
                    Button(isSelected ? "● \(kind.label)" : kind.label) {
                        form.kind = kind
                        container.notifyUpdate()
                    }
                }
            }

            // Main fields scroll view
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    // Quick URL fill
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection URL (optional shortcut):")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        TextField("e.g. postgres://user:password@localhost:5432/db", text: bind(\.url))
                    }

                    // Host & Port (or file for SQLite)
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

                    // Database name
                    if form.kind != .sqlite {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(form.kind == .redis ? "Database index (0-15):" : "Database:")
                                .font(.caption)
                                .foregroundColor(Color(white: 0.5))
                            TextField(form.kind == .redis ? "0" : "my_database", text: bind(\.database))
                        }
                    }

                    // Username & Password
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

                    // Display Name & Environment
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display Name:")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.5))
                        TextField(form.suggestedName.isEmpty ? "Display Name" : form.suggestedName, text: bind(\.name))
                    }

                    // Environment Picker
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

                    // Read-only toggle
                    HStack(spacing: 8) {
                        Button(form.readOnly ? "☑ Read-only connection" : "☐ Read-only connection") {
                            form.readOnly.toggle()
                            container.notifyUpdate()
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            // Test and Action Footer
            HStack(spacing: 12) {
                Button("Test Connection") {
                    Task {
                        if let manager = app.manager {
                            await form.runTest(using: manager)
                        }
                        container.notifyUpdate()
                    }
                }

                // Test state feedback
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

                Button(form.isEditing ? "Save Changes" : "Save & Connect") {
                    Task {
                        await app.saveForm(connect: true)
                        container.notifyUpdate()
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 600)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<ConnectionFormModel, String>) -> Binding<String> {
        Binding(
            get: { form[keyPath: keyPath] },
            set: { form[keyPath: keyPath] = $0 }
        )
    }
}

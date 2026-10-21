import AppKit
import DBClientKit
import SwiftUI

/// One sheet: paste a URL or fill the fields, then Test and Save.
struct ConnectSheet: View {
    @Environment(AppState.self) private var app
    @Bindable var form: ConnectionFormModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $form.url, prompt: Text("postgres://user:password@host:5432/database"))
                        .font(.body.monospaced())
                    if let error = form.urlError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Pasting a URL fills in the fields below. The password is stored in your keychain, never in the settings file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Name", text: $form.name, prompt: Text("Shown in the sidebar"))
                    Picker("Engine", selection: $form.kind) {
                        ForEach(DatabaseKind.all, id: \.self) { Text($0.label).tag($0) }
                    }
                    if form.kind == .sqlite {
                        HStack {
                            TextField("File", text: $form.host, prompt: Text("/path/to/database.db"))
                            Button("Choose…", action: chooseFile)
                        }
                    } else {
                        TextField("Host", text: $form.host)
                        TextField("Port", text: $form.port)
                        TextField(databaseLabel, text: $form.database, prompt: Text(databasePrompt))
                        TextField("User", text: $form.username)
                        SecureField("Password", text: $form.password, prompt: Text(form.isEditing ? "Unchanged" : "Optional"))
                            .onChange(of: form.password) { form.passwordChanged() }
                    }
                }

                Section("Safety") {
                    Picker("Environment", selection: $form.environment) {
                        ForEach(EnvironmentTag.all, id: \.self) { env in
                            Label(env.label, systemImage: "circle.fill").tag(env).foregroundStyle(env.color)
                        }
                    }
                    Toggle("Read-only", isOn: $form.readOnly)
                    if form.kind != .sqlite {
                        Picker("TLS", selection: $form.tls) {
                            Text("Prefer").tag(TlsMode.prefer)
                            Text("Require").tag(TlsMode.require)
                            Text("Disable").tag(TlsMode.disable)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: Space.s) {
                testStatus
                Spacer()
                Button("Test") { if let m = app.manager { Task { await form.runTest(using: m) } } }
                    .disabled(form.test == .testing || app.manager == nil)
                Button("Cancel", role: .cancel) { app.form = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await app.saveForm(connect: false) } }
                Button("Save & Connect") { Task { await app.saveForm(connect: true) } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.m)
        }
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    @ViewBuilder
    private var testStatus: some View {
        if let error = form.saveError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        } else {
            switch form.test {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .succeeded(let version):
                Label(version, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private var databaseLabel: String {
        form.kind == .redis ? "Database index" : "Database"
    }

    private var databasePrompt: String {
        switch form.kind {
        case .redis: "0"
        case .postgres: "postgres"
        default: "Optional"
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            form.host = url.path
            if form.name.isEmpty { form.name = url.lastPathComponent }
        }
    }
}

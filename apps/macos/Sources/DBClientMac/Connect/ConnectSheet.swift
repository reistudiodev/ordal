import AppKit
import DBClientKit
import SwiftUI

/// Pick an engine, then fill in the fields that engine needs. A pasted URL
/// is an optional shortcut, not the main path.
struct ConnectSheet: View {
    @Environment(AppState.self) private var app
    @Bindable var form: ConnectionFormModel
    @State private var showURL = false
    /// Errors for empty required fields appear only after Test or Save.
    @State private var attempted = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(form.isEditing ? "Edit Connection" : "New Connection")
                    .font(.title3.weight(.semibold))
                EnginePicker(selection: $form.kind)
                    .disabled(form.isEditing)
            }
            .padding([.horizontal, .top], Space.l)
            .padding(.bottom, Space.s)

            Form {
                if !form.isEditing {
                    Section {
                        DisclosureGroup("Fill from a connection URL", isExpanded: $showURL) {
                            TextField("URL", text: $form.url, prompt: Text(urlExample))
                                .font(.body.monospaced())
                                .labelsHidden()
                            if let error = form.urlError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }

                switch form.kind {
                case .postgres, .mySql: serverEngineSections
                case .sqlite: sqliteSections
                case .mongoDb: mongoSections
                case .redis: redisSections
                }

                Section("Name and safety") {
                    TextField("Name", text: $form.name, prompt: Text(form.suggestedName.isEmpty ? "Shown in the sidebar" : form.suggestedName))
                    Picker("Environment", selection: $form.environment) {
                        ForEach(EnvironmentTag.all, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Read-only", isOn: $form.readOnly)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 620)
        .onAppear { showURL = !form.url.isEmpty }
    }

    // MARK: Engine sections

    @ViewBuilder
    private var serverEngineSections: some View {
        Section("Server") {
            field("Host", $form.host, prompt: "localhost", error: .host)
            field("Port", $form.port, prompt: String(form.kind.defaultPort), error: .port)
            field("Database", $form.database, prompt: form.databasePlaceholder, error: .database)
        }
        loginSection(userPrompt: form.kind == .postgres ? "postgres" : "root")
        Section {
            Picker("SSL", selection: $form.tls) {
                Text("Prefer").tag(TlsMode.prefer)
                Text("Require").tag(TlsMode.require)
                Text("Disable").tag(TlsMode.disable)
            }
        } header: {
            Text("Security")
        } footer: {
            Text(tlsFooter).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sqliteSections: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(spacing: Space.s) {
                    TextField("File", text: $form.host, prompt: Text("~/data/app.db"))
                    Button("Choose…", action: chooseFile)
                    Button("Create New…", action: createFile)
                }
                errorText(.file, hasValue: !form.host.isEmpty)
            }
        } header: {
            Text("Database file")
        } footer: {
            Text("SQLite keeps the whole database in one file on this Mac. No server, user or password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var mongoSections: some View {
        Section {
            Picker("Deployment", selection: $form.mongoTopology) {
                ForEach(ConnectionFormModel.MongoTopology.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch form.mongoTopology {
            case .standalone:
                field("Host", $form.host, prompt: "localhost", error: .host)
                field("Port", $form.port, prompt: "27017", error: .port)
                Toggle("Connect directly", isOn: $form.directConnection)
                    .help("Talk only to this server, even if it belongs to a replica set")
            case .replicaSet:
                VStack(alignment: .leading, spacing: Space.hairline) {
                    TextField("Hosts", text: $form.mongoHosts, prompt: Text("db1.example.com:27017\ndb2.example.com:27017"), axis: .vertical)
                        .lineLimit(2...6)
                    errorText(.hosts, hasValue: !form.mongoHosts.isEmpty)
                }
                TextField("Replica set name", text: $form.replicaSetName, prompt: Text("rs0"))
            case .srv:
                field("Cluster host", $form.host, prompt: "cluster0.abcde.mongodb.net", error: .host)
            }
            field("Default database", $form.database, prompt: form.databasePlaceholder, error: .database)
        } header: {
            Text("Deployment")
        } footer: {
            Text(form.mongoTopology == .srv
                 ? "Use this for MongoDB Atlas and other mongodb+srv:// addresses. TLS is on by default."
                 : "A replica set lists one or more members; the driver discovers the rest.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Login") {
            TextField("User", text: $form.username, prompt: Text("Optional"))
            passwordField
            TextField("Auth database", text: $form.authSource, prompt: Text("admin"))
                .help("The database the user was created in (authSource)")
        }
        Section("Security") {
            Picker("TLS", selection: $form.tls) {
                Text("Default").tag(TlsMode.prefer)
                Text("Require").tag(TlsMode.require)
                Text("Disable").tag(TlsMode.disable)
            }
        }
    }

    @ViewBuilder
    private var redisSections: some View {
        Section("Server") {
            field("Host", $form.host, prompt: "localhost", error: .host)
            field("Port", $form.port, prompt: "6379", error: .port)
            field("Database index", $form.database, prompt: "0", error: .database)
        }
        Section {
            TextField("Username", text: $form.username, prompt: Text("Optional"))
            passwordField
        } header: {
            Text("Login")
        } footer: {
            Text("Leave the username empty for a plain password (requirepass). Redis 6+ ACL users need both.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Security") {
            Toggle("Use TLS", isOn: Binding(get: { form.tls == .require }, set: { form.tls = $0 ? .require : .disable }))
        }
    }

    private func loginSection(userPrompt: String) -> some View {
        Section("Login") {
            TextField("User", text: $form.username, prompt: Text(userPrompt))
            passwordField
        }
    }

    private var passwordField: some View {
        SecureField("Password", text: $form.password, prompt: Text(form.isEditing ? "Unchanged" : "Optional"))
            .onChange(of: form.password) { form.passwordChanged() }
    }

    // MARK: Fields and errors

    private func field(_ label: String, _ text: Binding<String>, prompt: String, error: ConnectionFormModel.Field) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField(label, text: text, prompt: Text(prompt))
            errorText(error, hasValue: !text.wrappedValue.isEmpty)
        }
    }

    @ViewBuilder
    private func errorText(_ field: ConnectionFormModel.Field, hasValue: Bool) -> some View {
        if let message = form.problems[field], attempted || hasValue {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Error: \(message)")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.s) {
            testStatus
            Spacer()
            Button("Test") { submit { if let m = app.manager { await form.runTest(using: m) } } }
                .disabled(form.test == .testing || app.manager == nil)
            Button("Cancel", role: .cancel) { app.form = nil }
                .keyboardShortcut(.cancelAction)
            Button("Save") { submit { await app.saveForm(connect: false) } }
            Button("Save & Connect") { submit { await app.saveForm(connect: true) } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Space.m)
    }

    /// Runs `action` only when the form is valid; otherwise reveals the errors.
    private func submit(_ action: @escaping () async -> Void) {
        attempted = true
        guard form.canSave else { return }
        Task { await action() }
    }

    @ViewBuilder
    private var testStatus: some View {
        if let error = form.saveError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        } else if attempted, !form.canSave {
            Label("Fix the highlighted fields", systemImage: "exclamationmark.circle").foregroundStyle(.red)
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

    // MARK: Copy

    private var urlExample: String {
        switch form.kind {
        case .postgres: "postgres://user:password@host:5432/database"
        case .mySql: "mysql://user:password@host:3306/database"
        case .sqlite: "sqlite:///path/to/database.db"
        case .mongoDb: "mongodb+srv://user:password@cluster0.example.net/app"
        case .redis: "redis://:password@host:6379/0"
        }
    }

    private var tlsFooter: String {
        switch form.tls {
        case .prefer: "Uses SSL when the server offers it, otherwise connects without."
        case .require: "Refuses to connect without SSL. Recommended for anything outside your machine."
        case .disable: "Never uses SSL. Only for local servers."
        }
    }

    // MARK: SQLite files

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            form.host = url.path
        }
    }

    private func createFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.db"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try form.createSQLiteFile(at: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Five engine tiles; the form below follows the selection.
private struct EnginePicker: View {
    @Binding var selection: DatabaseKind

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(DatabaseKind.all, id: \.self) { kind in
                let selected = kind == selection
                Button {
                    selection = kind
                } label: {
                    VStack(spacing: Space.hairline) {
                        Image(systemName: symbol(kind)).font(.title3).frame(height: 24)
                        Text(title(kind)).font(.callout.weight(.medium)).lineLimit(1)
                        Text(caption(kind)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func title(_ kind: DatabaseKind) -> String {
        switch kind {
        case .postgres: "PostgreSQL"
        case .mySql: "MySQL"
        case .sqlite: "SQLite"
        case .mongoDb: "MongoDB"
        case .redis: "Redis"
        }
    }

    private func caption(_ kind: DatabaseKind) -> String {
        switch kind {
        case .postgres: "Server"
        case .mySql: "and MariaDB"
        case .sqlite: "Local file"
        case .mongoDb: "Documents"
        case .redis: "Key-value"
        }
    }

    private func symbol(_ kind: DatabaseKind) -> String {
        switch kind {
        case .postgres: "cylinder"
        case .mySql: "cylinder.split.1x2"
        case .sqlite: "doc"
        case .mongoDb: "curlybraces"
        case .redis: "bolt.horizontal"
        }
    }
}

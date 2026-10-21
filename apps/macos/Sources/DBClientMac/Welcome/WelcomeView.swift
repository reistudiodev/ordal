import DBClientKit
import SwiftUI

/// Recent connections as cards, plus one field that takes a pasted URL.
struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @State private var url = ""
    @State private var pendingDelete: ConnectionConfig?

    var body: some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.s) {
                Text("DB Client")
                    .font(.largeTitle.weight(.semibold))
                Text("PostgreSQL, MySQL, MariaDB, SQLite, MongoDB and Redis")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Space.xl)

            HStack(spacing: Space.s) {
                TextField("Paste a connection URL: postgres://, mysql://, mongodb+srv://, redis://", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .controlSize(.large)
                    .onSubmit(open)
                    .accessibilityLabel("Connection URL")
                Button("New Connection", action: open)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: 640)

            if app.connections.isEmpty {
                ContentUnavailableView {
                    Label("Add your first connection", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Paste a URL above, or choose New Connection to fill in host, port, database and user.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Space.m)], spacing: Space.m) {
                        ForEach(app.connections) { config in
                            ConnectionCard(config: config, onDelete: { pendingDelete = config })
                        }
                    }
                    .padding(Space.l)
                }
            }
        }
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Connection", role: .destructive) {
                if let c = pendingDelete { Task { await app.delete(c.id) } }
            }
        } message: {
            Text("The saved settings, the password in your keychain and the query history are removed. The database itself is not touched.")
        }
    }

    private func open() {
        app.newConnection(url: url)
        url = ""
    }
}

private struct ConnectionCard: View {
    @Environment(AppState.self) private var app
    let config: ConnectionConfig
    let onDelete: () -> Void

    var body: some View {
        Button {
            Task { await app.connect(config.id) }
        } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Circle().fill(config.accent).frame(width: 10, height: 10)
                    Text(config.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if app.connectingID == config.id {
                        ProgressView().controlSize(.small)
                    } else if app.isOpen(config.id) {
                        Text("Open").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(config.kind.label).font(.subheadline).foregroundStyle(.secondary)
                Text(config.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Space.hairline) {
                    if config.environment.showsChrome { Pill(text: config.environment.label, color: config.environment.color) }
                    if config.readOnly { Pill(text: "Read-only", color: .secondary) }
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(app.connectingID != nil)
        .contextMenu {
            Button("Connect") { Task { await app.connect(config.id) } }
            Button("Edit…") { app.edit(config) }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(config.name), \(config.kind.label), \(config.environment.label)")
        .accessibilityHint("Connects to this database")
    }
}

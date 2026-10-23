import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern native cross-platform Welcome View displaying saved connection cards and quick connect actions.
public struct WelcomeView: View {
    let container: AppStateContainer
    @State private var url: String = ""

    private var app: AppState { container.app }

    public init(container: AppStateContainer) {
        self.container = container
    }

    public var body: some View {
        VStack(spacing: 24) {
            welcomeHeader

            FastConnectBar(
                url: Binding(get: { url }, set: { url = $0 }),
                onSubmit: {
                    app.newConnection(url: url)
                    url = ""
                    container.notifyUpdate()
                }
            )

            if app.connections.isEmpty {
                emptyConnectionsPlaceholder
            } else {
                connectionsList
            }
        }
        .padding(16)
        .background(Color.uiBackground)
    }

    private var welcomeHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ModernIcon(.database, color: Color.uiAccent, size: 28, strokeWidth: 1.6)
                Text("Ordal")
                    .font(.largeTitle)
                    .foregroundColor(Color.uiTextPrimary)
            }
            Text("PostgreSQL · MySQL · MariaDB · SQLite · MongoDB · Redis")
                .foregroundColor(Color.uiTextMuted)
                .font(.subheadline)
        }
        .padding(.top, 24)
    }

    private var emptyConnectionsPlaceholder: some View {
        VStack(spacing: 12) {
            Text("No saved connections yet")
                .font(.title2)
                .foregroundColor(Color.uiTextPrimary)
            Text("Paste a URL above, or click New Connection to configure your database.")
                .foregroundColor(Color.uiTextMuted)
        }
        .frame(maxHeight: .infinity)
    }

    private var connectionsList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                ForEach(app.connections, id: \.id) { config in
                    ConnectionCard(container: container, config: config)
                }
            }
            .padding(20)
        }
    }
}

private struct FastConnectBar: View {
    let url: Binding<String>
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Paste a connection URL (e.g. postgres://user:pass@localhost/db)", text: url)
                .frame(minWidth: 420)

            Button {
                onSubmit()
            } label: {
                HStack(spacing: 5) {
                    ModernIcon(.plus, color: Color.white, size: 12)
                    Text("New Connection")
                        .font(.body)
                        .foregroundColor(Color.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.uiAccent)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }
}

public struct ConnectionCard: View {
    let container: AppStateContainer
    let config: ConnectionConfig

    private var app: AppState { container.app }

    public var body: some View {
        HStack(spacing: 16) {
            Circle()
                .foregroundColor(Color.from(pair: config.accentColors))
                .frame(width: 10, height: 10)

            connectionDetails

            Spacer()

            connectActionButtons
        }
        .padding(14)
        .background(Color.uiPanel)
        .cornerRadius(8)
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(config.name)
                    .font(.headline)
                    .foregroundColor(Color.uiTextPrimary)
                if config.environment.showsChrome {
                    Text(config.environment.label)
                        .font(.caption)
                        .foregroundColor(Color.from(pair: config.environment.colors))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.uiHover)
                        .cornerRadius(4)
                }
                if config.readOnly {
                    Text("read-only")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                }
            }
            HStack(spacing: 6) {
                Text(config.kind.label)
                    .font(.subheadline)
                    .foregroundColor(Color.uiAccent)
                Text("·")
                    .foregroundColor(Color.uiTextFaint)
                Text(config.address)
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)
            }
        }
    }

    @ViewBuilder
    private var connectActionButtons: some View {
        if app.connectingID == config.id {
            HStack(spacing: 5) {
                ModernIcon(.refresh, color: Color.uiAccent, size: 11)
                Text("Connecting...")
                    .foregroundColor(Color.uiAccent)
                    .font(.caption)
            }
        } else {
            Button {
                Task {
                    await app.connect(config.id)
                    container.notifyUpdate()
                }
            } label: {
                Text(app.isOpen(config.id) ? "Switch" : "Connect")
                    .font(.caption)
                    .foregroundColor(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.uiAccent)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }

        Button {
            app.edit(config)
            container.notifyUpdate()
        } label: {
            HStack(spacing: 4) {
                ModernIcon(.edit, color: Color.uiTextMuted, size: 10)
                Text("Edit")
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.uiHover)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)

        Button {
            Task {
                await app.delete(config.id)
                container.notifyUpdate()
            }
        } label: {
            Text("Delete")
                .font(.caption)
                .foregroundColor(Color.uiDanger)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.uiHover)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

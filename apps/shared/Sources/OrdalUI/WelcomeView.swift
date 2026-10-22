import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform Welcome View displaying saved connection cards and quick connect actions.
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
    }

    private var welcomeHeader: some View {
        VStack(spacing: 8) {
            Text("Ordal")
                .font(.largeTitle)
            Text("PostgreSQL · MySQL · MariaDB · SQLite · MongoDB · Redis")
                .foregroundColor(Color(white: 0.5))
                .font(.subheadline)
        }
        .padding(.top, 24)
    }

    private var emptyConnectionsPlaceholder: some View {
        VStack(spacing: 12) {
            Text("No saved connections yet")
                .font(.title2)
                .foregroundColor(Color(white: 0.5))
            Text("Paste a URL above, or click New Connection to configure your database.")
                .foregroundColor(Color(white: 0.4))
        }
        .frame(maxHeight: .infinity)
    }

    private var connectionsList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                ForEach(app.connections, id: \.id) { config in
                    ConnectionCard(container: container, config: config)
                }
            }
            .padding(24)
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
            Button("New Connection") {
                onSubmit()
            }
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
                .frame(width: 12, height: 12)

            connectionDetails

            Spacer()

            connectActionButtons
        }
        .padding(16)
        .background(
            Color.adaptive(
                light: Color(white: 0.94),
                dark: Color(white: 0.16)
            )
        )
        .cornerRadius(8)
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(config.name)
                    .font(.headline)
                if config.environment.showsChrome {
                    Text(config.environment.label)
                        .font(.caption)
                        .foregroundColor(Color.from(pair: config.environment.colors))
                }
                if config.readOnly {
                    Text("read-only")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))
                }
            }
            HStack(spacing: 6) {
                Text(config.kind.label)
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.6))
                Text("·")
                    .foregroundColor(Color(white: 0.4))
                Text(config.address)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }
        }
    }

    @ViewBuilder
    private var connectActionButtons: some View {
        if app.connectingID == config.id {
            Text("Connecting...")
                .foregroundColor(Color(white: 0.6))
                .font(.caption)
        } else {
            Button(app.isOpen(config.id) ? "Switch" : "Connect") {
                Task {
                    await app.connect(config.id)
                    container.notifyUpdate()
                }
            }
        }

        Button("Edit") {
            app.edit(config)
            container.notifyUpdate()
        }

        Button("Delete") {
            Task {
                await app.delete(config.id)
                container.notifyUpdate()
            }
        }
    }
}

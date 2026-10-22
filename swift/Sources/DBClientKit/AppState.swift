import Foundation
import Observation

/// The app's root state: saved connections and the open workspaces.
@MainActor @Observable
public final class AppState {
    public let manager: ConnectionManager?
    public private(set) var startupError: String?
    public private(set) var connections: [ConnectionConfig] = []
    public private(set) var workspaces: [WorkspaceModel] = []
    public var activeWorkspaceID: String?
    public private(set) var connectingID: String?
    public private(set) var connectError: String?
    /// The connection sheet is shown while this is set.
    public var form: ConnectionFormModel?
    public var showInspector = false
    public var showPalette = false
    /// Shows the welcome screen even when connections are open.
    public var showWelcome = false

    public init(manager: ConnectionManager) {
        self.manager = manager
        reload()
    }

    /// Uses the platform's standard directories and keychain. For development,
    /// `DBCLIENT_HOME=/some/dir` keeps everything in that directory instead,
    /// with passwords held in memory only.
    public init() {
        do {
            if let home = ProcessInfo.processInfo.environment["DBCLIENT_HOME"], !home.isEmpty {
                manager = try ConnectionManager.withDirectory(dir: home, useKeychain: false)
            } else {
                manager = try ConnectionManager()
            }
            reload()
        } catch {
            manager = nil
            startupError = describe(error)
        }
    }

    public func reload() {
        connections = (manager?.list() ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var activeWorkspace: WorkspaceModel? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    public func isOpen(_ id: String) -> Bool {
        workspaces.contains { $0.id == id }
    }

    // MARK: Connection sheet

    public func newConnection(url: String = "") {
        let form = ConnectionFormModel()
        if !url.isEmpty { form.url = url }
        self.form = form
    }

    public func edit(_ config: ConnectionConfig) {
        form = ConnectionFormModel(editing: config)
    }

    /// Saves the sheet; with `connect`, opens the connection too.
    public func saveForm(connect: Bool) async {
        guard let form, let manager, let saved = form.save(using: manager) else { return }
        self.form = nil
        reload()
        if connect { await self.connect(saved.id) }
    }

    public func delete(_ id: String) async {
        await disconnect(id)
        do {
            try manager?.delete(id: id)
        } catch {
            connectError = describe(error)
        }
        reload()
    }

    // MARK: Workspaces

    public func connect(_ id: String) async {
        showWelcome = false
        if isOpen(id) {
            activeWorkspaceID = id
            return
        }
        guard let manager, let config = connections.first(where: { $0.id == id }) else { return }
        connectingID = id
        connectError = nil
        defer { connectingID = nil }
        do {
            let session = try await manager.open(id: id)
            let workspace = WorkspaceModel(config: config, session: session, manager: manager)
            workspaces.append(workspace)
            activeWorkspaceID = id
            await workspace.start()
        } catch {
            connectError = describe(error)
        }
    }

    public func disconnect(_ id: String) async {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: i)
        if activeWorkspaceID == id { activeWorkspaceID = workspaces.last?.id }
        await workspace.close()
    }

    /// Reconnects an open workspace, or opens the connection if it isn't.
    public func reconnect(_ id: String) async {
        if let ws = workspaces.first(where: { $0.id == id }) {
            activeWorkspaceID = id
            await ws.reconnect()
        } else {
            await connect(id)
        }
    }

    public func dismissConnectError() {
        connectError = nil
    }
}

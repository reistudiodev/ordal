import Foundation
import Observation

/// Everything for one open connection: browser, tabs, inspector, status.
@MainActor @Observable
public final class WorkspaceModel: Identifiable {
    public enum Tab: Identifiable {
        case query(QueryTabModel)
        case table(TableTabModel)
        case schema(SchemaTabModel)

        public var id: UUID {
            switch self {
            case .query(let q): q.id
            case .table(let t): t.id
            case .schema(let s): s.id
            }
        }

        @MainActor public var title: String {
            switch self {
            case .query(let q): q.title
            case .table(let t): t.title
            case .schema(let s): s.title
            }
        }
    }

    public enum ConnectionState: Equatable {
        case connected
        case lost(String)
        case reconnecting
    }

    /// The cell shown (and, for table tabs, edited) in the inspector.
    public struct InspectedCell: Equatable {
        public let column: ColumnInfo
        public let value: Value
        public let row: Int
        public let columnIndex: Int
        /// The table tab the cell came from; nil for query results (read-only).
        public let tableTab: UUID?

        public init(column: ColumnInfo, value: Value, row: Int, columnIndex: Int, tableTab: UUID? = nil) {
            self.column = column
            self.value = value
            self.row = row
            self.columnIndex = columnIndex
            self.tableTab = tableTab
        }
    }

    public let config: ConnectionConfig
    public private(set) var session: Session
    public let browser: BrowserModel
    public private(set) var state: ConnectionState = .connected
    public private(set) var tabs: [Tab] = []
    public var selectedTabID: UUID?
    public private(set) var serverInfo: ServerInfo?
    public private(set) var latencyMs: Double?
    public var inspected: InspectedCell?
    public var exportTarget: ExportTarget?
    public var isExporting = false
    public var exportProgress: String?
    public var renameTarget: RenameTarget?
    public var columnTypeTarget: ColumnTypeTarget?

    private let manager: ConnectionManager
    private var queryCounter = 0

    public nonisolated var id: String { config.id }

    init(config: ConnectionConfig, session: Session, manager: ConnectionManager) {
        self.config = config
        self.session = session
        self.manager = manager
        self.browser = BrowserModel(session: session)
    }

    public func start() async {
        serverInfo = try? await session.serverInfo()
        await browser.loadRoots()
        await refreshLatency()
        if tabs.isEmpty { newQueryTab() }
    }

    public func refreshLatency() async {
        do {
            latencyMs = try await session.ping()
            if case .lost = state { state = .connected }
        } catch {
            latencyMs = nil
            if state != .reconnecting { state = .lost(describe(error)) }
        }
    }

    /// Opens a fresh session and moves every tab and the browser onto it.
    /// Tabs, editor text and staged edits are kept.
    public func reconnect() async {
        state = .reconnecting
        do {
            let fresh = try await manager.open(id: config.id)
            let old = session
            session = fresh
            browser.rebind(fresh)
            for tab in tabs {
                switch tab {
                case .query(let q): q.session = fresh
                case .table(let t): t.rebind(fresh)
                case .schema(let s): s.rebind(fresh)
                }
            }
            state = .connected
            Task { await old.close() }
            serverInfo = try? await fresh.serverInfo()
            await browser.loadRoots()
            await refreshLatency()
        } catch {
            state = .lost(describe(error))
        }
    }

    private func watch(_ tab: QueryTabModel) {
        tab.onConnectionLost = { [weak self] message in
            self?.state = .lost(message)
        }
    }

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    public var activeQuery: QueryTabModel? {
        if case .query(let q) = selectedTab { return q }
        return nil
    }

    public var activeTable: TableTabModel? {
        if case .table(let t) = selectedTab { return t }
        return nil
    }

    /// The editor that ⌘↵, ⌘S and Format act on: a query tab, or a table
    /// tab showing its Query segment.
    public var activeEditor: QueryTabModel? {
        switch selectedTab {
        case .query(let q): q
        case .table(let t) where t.segment == .query: t.query
        default: nil
        }
    }

    @discardableResult
    public func newQueryTab(text: String = "", database: String? = nil) -> QueryTabModel {
        queryCounter += 1
        let tab = QueryTabModel(title: "Query \(queryCounter)", text: text, session: session, manager: manager)
        tab.database = database
        tab.loadHistory()
        watch(tab)
        tabs.append(.query(tab))
        selectedTabID = tab.id
        return tab
    }

    /// Opens (or switches to) the data tab for a table, view or collection.
    public func openTable(_ node: TreeNode) {
        openTable(path: node.path, kind: node.kind)
    }

    /// Opens (or switches to) the data tab for the relation at `path`.
    public func openTable(path: [String], kind: NodeKind) {
        if let existing = tabs.first(where: { if case .table(let t) = $0 { t.path == path } else { false } }) {
            selectedTabID = existing.id
            return
        }
        let tab = TableTabModel(
            path: path, kind: kind, starter: starterQuery(path: path, kind: kind, detail: nil),
            database: database(for: path), session: session, manager: manager)
        watch(tab.query)
        tabs.append(.table(tab))
        selectedTabID = tab.id
        Task { await tab.start() }
    }

    /// Opens (or switches to) the relations diagram for a schema or database.
    public func openSchema(path: [String]) {
        if let existing = tabs.first(where: { if case .schema(let s) = $0 { s.path == path } else { false } }) {
            selectedTabID = existing.id
            return
        }
        let tab = SchemaTabModel(path: path, session: session)
        tabs.append(.schema(tab))
        selectedTabID = tab.id
        Task { await tab.start() }
    }

    /// The browse path whose relations make sense to draw for `node`.
    public func relationsPath(for node: TreeNode) -> [String]? {
        switch (config.kind, node.kind) {
        case (.postgres, .schema), (.mySql, .database), (.sqlite, .database), (.mongoDb, .database): node.path
        default: nil
        }
    }

    /// Opens a `.sql` file in a new query tab.
    public func openFile(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let tab = newQueryTab(text: text)
        tab.title = url.deletingPathExtension().lastPathComponent
        tab.loaded(from: url)
    }

    public func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if case .query(let q) = tabs[i] { q.cancel() }
        if case .table(let t) = tabs[i] { t.query.cancel() }
        tabs.remove(at: i)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
    }

    public func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(i + offset + tabs.count) % tabs.count].id
    }

    /// The database a browse path belongs to, for "New query here".
    public func database(for path: [String]) -> String? {
        switch config.kind {
        case .postgres, .mySql, .mongoDb, .redis: path.first
        case .sqlite: nil
        }
    }

    // MARK: - Export
    public func presentExport(for node: TreeNode) {
        let kind: ExportTarget.Kind
        switch node.kind {
        case .table: kind = .table
        case .view: kind = .view
        case .collection: kind = .collection
        case .database: kind = .database
        case .schema: kind = .schema
        default: return
        }
        exportTarget = ExportTarget(name: node.name, path: node.path, kind: kind)
    }

    public func presentExport(name: String, path: [String], kind: ExportTarget.Kind) {
        exportTarget = ExportTarget(name: name, path: path, kind: kind)
    }

    public func dismissExport() {
        exportTarget = nil
        isExporting = false
        exportProgress = nil
    }

    // MARK: - Rename
    public func presentRename(for node: TreeNode) {
        let kind: RenameTarget.Kind
        switch node.kind {
        case .table: kind = .table
        case .view: kind = .view
        case .collection: kind = .collection
        case .database: kind = .database
        case .schema: kind = .schema
        default: return
        }
        renameTarget = RenameTarget(name: node.name, path: node.path, kind: kind)
    }

    public func presentRename(name: String, path: [String], kind: RenameTarget.Kind) {
        renameTarget = RenameTarget(name: name, path: path, kind: kind)
    }

    public func dismissRename() {
        renameTarget = nil
    }

    public func renameNode(target: RenameTarget, to newName: String) async throws {
        try await SchemaManager.executeRename(
            session: session,
            engine: config.kind,
            target: target,
            newName: newName
        )

        // Compute new path
        var newPath = target.path
        if !newPath.isEmpty {
            newPath[newPath.count - 1] = newName
        }

        // Update any open table tab matching this path
        for tab in tabs {
            if case .table(let t) = tab, t.path == target.path {
                await t.updatePath(newPath)
            }
        }

        // Refresh object browser
        if target.path.count > 1 {
            let parentPath = Array(target.path.dropLast())
            if let parentNode = browser.loadedNodes.first(where: { $0.path == parentPath }) {
                await browser.load(parentNode, force: true)
            } else {
                await browser.loadRoots()
            }
        } else {
            await browser.loadRoots()
        }

        dismissRename()
    }

    // MARK: - Change Column Type
    public func presentChangeColumnType(column: String, currentType: String, tablePath: [String], tableName: String) {
        columnTypeTarget = ColumnTypeTarget(column: column, currentType: currentType, tablePath: tablePath, tableName: tableName)
    }

    public func dismissChangeColumnType() {
        columnTypeTarget = nil
    }

    public func changeColumnType(target: ColumnTypeTarget, newType: String) async throws {
        var tableMeta: TableMeta? = nil
        var matchingTab: TableTabModel? = nil
        for tab in tabs {
            if case .table(let t) = tab, t.path == target.tablePath {
                matchingTab = t
                tableMeta = t.pager.meta
                break
            }
        }

        if tableMeta == nil {
            tableMeta = try? await session.tableMeta(path: target.tablePath)
        }

        try await SchemaManager.alterColumnType(
            session: session,
            engine: config.kind,
            path: target.tablePath,
            column: target.column,
            newType: newType,
            tableMeta: tableMeta
        )

        if let matchingTab {
            await matchingTab.pager.refresh()
            await matchingTab.loadStructure()
        }

        dismissChangeColumnType()
    }

    func close() async {
        for tab in tabs { if case .query(let q) = tab { q.cancel() } }
        await session.close()
    }
}

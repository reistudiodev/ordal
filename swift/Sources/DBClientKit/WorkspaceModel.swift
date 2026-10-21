import Foundation
import Observation

/// Everything for one open connection: browser, tabs, inspector, status.
@MainActor @Observable
public final class WorkspaceModel: Identifiable {
    public enum Tab: Identifiable {
        case query(QueryTabModel)
        case table(TableTabModel)

        public var id: UUID {
            switch self {
            case .query(let q): q.id
            case .table(let t): t.id
            }
        }

        @MainActor public var title: String {
            switch self {
            case .query(let q): q.title
            case .table(let t): t.title
            }
        }
    }

    /// The cell shown in the inspector.
    public struct InspectedCell: Equatable {
        public let column: ColumnInfo
        public let value: Value
        public let row: Int

        public init(column: ColumnInfo, value: Value, row: Int) {
            self.column = column
            self.value = value
            self.row = row
        }
    }

    public let config: ConnectionConfig
    public let session: Session
    public let browser: BrowserModel
    public private(set) var tabs: [Tab] = []
    public var selectedTabID: UUID?
    public private(set) var serverInfo: ServerInfo?
    public private(set) var latencyMs: Double?
    public var inspected: InspectedCell?

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
        latencyMs = try? await session.ping()
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

    @discardableResult
    public func newQueryTab(text: String = "", database: String? = nil) -> QueryTabModel {
        queryCounter += 1
        let tab = QueryTabModel(title: "Query \(queryCounter)", text: text, session: session, manager: manager)
        tab.database = database
        tab.loadHistory()
        tabs.append(.query(tab))
        selectedTabID = tab.id
        return tab
    }

    /// Opens (or switches to) the data tab for a table, view or collection.
    public func openTable(_ node: TreeNode) {
        if let existing = tabs.first(where: { if case .table(let t) = $0 { t.path == node.path } else { false } }) {
            selectedTabID = existing.id
            return
        }
        let tab = TableTabModel(path: node.path, kind: node.kind, session: session)
        tabs.append(.table(tab))
        selectedTabID = tab.id
        Task { await tab.start() }
    }

    public func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if case .query(let q) = tabs[i] { q.cancel() }
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

    func close() async {
        for tab in tabs { if case .query(let q) = tab { q.cancel() } }
        await session.close()
    }
}

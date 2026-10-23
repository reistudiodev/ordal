import Foundation
import Observation

/// A table, view or collection tab: data first, then structure, DDL and a
/// query editor scoped to this table.
@MainActor @Observable
public final class TableTabModel: Identifiable {
    public enum Segment: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        case indexes = "Indexes"
        case ddl = "DDL"
        case query = "Query"
        public var id: String { rawValue }
    }

    public let id = UUID()
    public private(set) var path: [String]
    public let kind: NodeKind
    public var segment: Segment = .data
    public let pager: TablePager
    /// The Query segment's editor, prefilled for this table.
    public let query: QueryTabModel
    public private(set) var structure: [BrowseNode] = []
    public private(set) var indexes: [BrowseNode] = []
    public private(set) var ddl = ""
    public private(set) var structureError: String?

    private var session: Session

    init(path: [String], kind: NodeKind, starter: String, database: String?, session: Session, manager: ConnectionManager) {
        self.path = path
        self.kind = kind
        self.session = session
        self.pager = TablePager(session: session, path: path)
        self.query = QueryTabModel(title: path.last ?? "query", text: starter, session: session, manager: manager)
        query.database = database
        query.loadHistory()
    }

    public var title: String { path.last ?? "table" }

    public var segments: [Segment] {
        if session.config().kind == .mongoDb {
            return [.data, .structure, .indexes, .query]
        }
        return session.config().kind.isSQL ? [.data, .structure, .indexes, .ddl, .query] : [.data, .structure, .indexes, .query]
    }

    public func start() async {
        await pager.start()
        await loadStructure()
    }

    func rebind(_ session: Session) {
        self.session = session
        pager.rebind(session)
        query.session = session
    }

    /// Updates relation path and refreshes pager and structure when table is renamed.
    public func updatePath(_ newPath: [String]) async {
        self.path = newPath
        pager.updatePath(newPath)
        await pager.refresh()
        await loadStructure()
    }

    /// Alters a column's data type, refreshes pager data, metadata, and the structure tab.
    public func changeColumnType(column: String, newType: String) async throws {
        try await SchemaManager.alterColumnType(
            session: session,
            engine: session.config().kind,
            path: path,
            column: column,
            newType: newType,
            tableMeta: pager.meta
        )
        await pager.refresh()
        await loadStructure()
    }

    public func loadStructure() async {
        do {
            let rawChildren = try await session.listChildren(path: path)
            if session.config().kind == .mongoDb {
                // In MongoDB, listChildren returns index nodes
                indexes = rawChildren
                if let meta = pager.meta {
                    structure = meta.columns.map { BrowseNode(name: $0.name, kind: .column, hasChildren: false, detail: $0.typeName) }
                } else {
                    structure = []
                }
            } else {
                indexes = rawChildren.filter { $0.kind == .index }
                structure = rawChildren.filter { $0.kind != .index }
            }
            ddl = makeDDL()
            structureError = nil
        } catch {
            structureError = describe(error)
        }
    }

    /// DDL rebuilt from the catalog columns (types, NOT NULL, primary key).
    func makeDDL() -> String {
        let engine = session.config().kind
        guard engine.isSQL else { return "" }
        let quote: (String) -> String = { name in
            engine == .mySql ? "`\(name)`" : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let relation = path.count == 4 ? "\(quote(path[1])).\(quote(path[3]))" : quote(path.last ?? "")
        if kind == .view {
            // A view's definition is a query, not columns; list what it returns.
            let cols = structure.map { "--   \($0.name)  \($0.detail ?? "")" }
            return "-- \(relation) is a view. Its columns:\n" + cols.joined(separator: "\n")
        }
        var pk: [String] = []
        let cols = structure.filter { $0.kind == .column }.map { col -> String in
            let parts = (col.detail ?? "").components(separatedBy: " · ")
            var line = "  \(quote(col.name)) \(parts.first ?? "")"
            if parts.contains("not null") { line += " NOT NULL" }
            if parts.contains("PK") { pk.append(quote(col.name)) }
            return line
        }
        var body = cols
        if !pk.isEmpty { body.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))") }
        return "CREATE TABLE \(relation) (\n\(body.joined(separator: ",\n"))\n);"
    }
}

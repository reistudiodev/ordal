import Foundation
import Observation

/// A table, view or collection tab: data first, then structure and DDL.
@MainActor @Observable
public final class TableTabModel: Identifiable {
    public enum Segment: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        case ddl = "DDL"
        public var id: String { rawValue }
    }

    public let id = UUID()
    public let path: [String]
    public let kind: NodeKind
    public var segment: Segment = .data
    public let pager: WindowPager
    public private(set) var structure: [BrowseNode] = []
    public private(set) var ddl = ""
    public private(set) var structureError: String?

    private let session: Session

    init(path: [String], kind: NodeKind, session: Session) {
        self.path = path
        self.kind = kind
        self.session = session
        self.pager = WindowPager(session: session, path: path)
    }

    public var title: String { path.last ?? "table" }

    public var segments: [Segment] {
        session.config().kind.isSQL ? Segment.allCases : [.data, .structure]
    }

    public func start() async {
        await pager.start()
        await loadStructure()
    }

    public func loadStructure() async {
        do {
            structure = try await session.listChildren(path: path)
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

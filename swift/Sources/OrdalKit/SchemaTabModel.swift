import Foundation
import Observation

public struct DiagramPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A relations diagram for one schema (SQL) or database (MongoDB): every
/// table as a card with all its columns, connectors from referencing column
/// to referenced column, and positions you can drag and that are remembered.
@MainActor @Observable
public final class SchemaTabModel: Identifiable {
    public let id = UUID()
    public let path: [String]
    public private(set) var graph: SchemaGraph?
    public private(set) var positions: [String: DiagramPoint] = [:]
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// The focused table: its relations are highlighted, others dimmed.
    public var selected: String?
    /// Show only the focused table and its direct neighbours.
    public var focusOnly = false
    /// A hovered column row, as (table, column).
    public var hovered: (table: String, column: String)?
    /// Tables hidden from the canvas until Tidy Up or reload.
    public private(set) var hidden: Set<String> = []
    /// Bumped on every change that moves cards or edges.
    public private(set) var version = 0

    private var session: Session
    private let defaults: UserDefaults

    /// For tests: a model over a ready-made graph.
    init(path: [String], session: Session, graph: SchemaGraph, defaults: UserDefaults) {
        self.path = path
        self.session = session
        self.defaults = defaults
        self.graph = graph
        self.positions = SchemaLayout.layout(graph)
    }

    init(path: [String], session: Session, defaults: UserDefaults = .standard) {
        self.path = path
        self.session = session
        self.defaults = defaults
    }

    public var title: String { "Relations · \(path.last ?? "")" }

    private var connectionID: String { session.config().id }

    public func start() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let g = try await session.schemaGraph(path: path)
            graph = g
            hidden = []
            // Saved positions win; new tables get auto-layout positions.
            let auto = SchemaLayout.layout(g)
            let saved = DiagramLayoutStore.load(connection: connectionID, path: path, defaults: defaults)
            positions = auto.merging(saved.filter { auto[$0.key] != nil }) { _, saved in saved }
            error = nil
            version += 1
        } catch {
            self.error = describe(error)
        }
    }

    func rebind(_ session: Session) {
        self.session = session
    }

    // MARK: Editing the layout

    /// Moves a card. During a drag pass `persist: false` on every step and
    /// `true` once at the end, so the layout is written to disk once.
    public func move(_ table: String, to point: DiagramPoint, persist: Bool = true) {
        positions[table] = DiagramPoint(x: max(0, point.x), y: max(0, point.y))
        if persist {
            DiagramLayoutStore.save(positions, connection: connectionID, path: path, defaults: defaults)
        }
        version += 1
    }

    /// The column row under `point`, if it is over a card's body (not its header).
    public func column(at point: DiagramPoint) -> (table: String, column: String)? {
        guard let name = table(at: point), let p = positions[name],
              let t = graph?.tables.first(where: { $0.name == name }) else { return nil }
        let y = point.y - p.y - SchemaLayout.headerHeight
        guard y >= 0 else { return nil }
        let i = Int(y / SchemaLayout.rowHeight)
        return i < t.columns.count ? (name, t.columns[i].name) : nil
    }

    /// The topmost visible card containing `point` (later cards draw on top).
    public func table(at point: DiagramPoint) -> String? {
        visibleTables.last { t in
            guard let p = positions[t.name] else { return false }
            return point.x >= p.x && point.x <= p.x + SchemaLayout.cardWidth
                && point.y >= p.y && point.y <= p.y + SchemaLayout.cardHeight(t)
        }?.name
    }

    /// Lays everything out again and forgets dragged positions.
    public func resetLayout() {
        guard let graph else { return }
        hidden = []
        positions = SchemaLayout.layout(graph)
        DiagramLayoutStore.clear(connection: connectionID, path: path, defaults: defaults)
        version += 1
    }

    public func hide(_ table: String) {
        hidden.insert(table)
        if selected == table { selected = nil }
        version += 1
    }

    // MARK: What to draw

    /// Tables on the canvas, after hiding and focus.
    public var visibleTables: [GraphTable] {
        guard let graph else { return [] }
        let keep = focusOnly ? focusSet : nil
        return graph.tables.filter { !hidden.contains($0.name) && (keep?.contains($0.name) ?? true) }
    }

    /// Routed connectors, recomputed only when something moved or changed.
    public var edges: [SchemaLayout.Edge] {
        let key = EdgeKey(version: version, focusOnly: focusOnly, selected: focusOnly ? selected : nil)
        if let cached = edgeCache, cached.key == key { return cached.edges }
        guard let graph else { return [] }
        let shown = Set(visibleTables.map(\.name))
        let hiddenNow = Set(graph.tables.map(\.name)).subtracting(shown)
        let edges = SchemaLayout.route(graph, positions: positions, hidden: hiddenNow)
        edgeCache = (key, edges)
        return edges
    }

    private struct EdgeKey: Equatable {
        let version: Int
        let focusOnly: Bool
        let selected: String?
    }

    @ObservationIgnored private var edgeCache: (key: EdgeKey, edges: [SchemaLayout.Edge])?

    /// The focused table and the tables it links to or from.
    public var focusSet: Set<String> {
        guard let selected, let graph else { return [] }
        var set: Set<String> = [selected]
        for r in graph.relations where r.fromTable == selected || r.toTable == selected {
            set.insert(r.fromTable)
            set.insert(r.toTable)
        }
        return set
    }

    public enum Emphasis { case normal, highlighted, dimmed }

    public func emphasis(of edge: SchemaLayout.Edge) -> Emphasis {
        if let h = hovered {
            let touches = (edge.fromTable == h.table && edge.fromColumn == h.column) || (edge.toTable == h.table && edge.toColumn == h.column)
            return touches ? .highlighted : .dimmed
        }
        guard let selected else { return .normal }
        return edge.fromTable == selected || edge.toTable == selected ? .highlighted : .dimmed
    }

    public func emphasis(ofTable name: String) -> Emphasis {
        guard selected != nil else { return .normal }
        return name == selected ? .highlighted : focusSet.contains(name) ? .normal : .dimmed
    }

    /// Columns that point at another table (drawn with a link glyph).
    public func isForeignKey(table: String, column: String) -> Bool {
        graph?.relations.contains { $0.fromTable == table && $0.fromColumns.contains(column) } ?? false
    }

    public func references(of table: String) -> [String] {
        Array(Set(graph?.relations.filter { $0.fromTable == table && $0.toTable != table }.map(\.toTable) ?? [])).sorted()
    }

    /// The best fuzzy match for a table name.
    public func find(_ query: String) -> String? {
        Fuzzy.filter(visibleTables.map(\.name), query: query) { $0 }.first
    }

    public static func cardHeight(_ table: GraphTable) -> Double { SchemaLayout.cardHeight(table) }

    /// The canvas size that fits every card plus room for edge loops.
    public var canvasSize: (width: Double, height: Double) {
        var w = 0.0, h = 0.0
        for t in visibleTables {
            guard let p = positions[t.name] else { continue }
            w = max(w, p.x + SchemaLayout.cardWidth)
            h = max(h, p.y + SchemaLayout.cardHeight(t))
        }
        return (max(w + 160, 800), max(h + 120, 600))
    }
}

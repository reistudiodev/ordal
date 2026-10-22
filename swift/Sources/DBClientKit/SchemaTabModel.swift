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

/// A relations diagram for one schema (SQL) or database (MongoDB): table
/// cards placed in layers so referenced tables sit left of the tables that
/// point at them, and every card can be dragged.
@MainActor @Observable
public final class SchemaTabModel: Identifiable {
    public static let cardWidth = 250.0
    public static let headerHeight = 34.0
    public static let rowHeight = 22.0
    /// Columns shown per card before "+ N more".
    public static let maxRows = 14
    static let columnGap = 120.0
    static let rowGap = 32.0

    public let id = UUID()
    public let path: [String]
    public private(set) var graph: SchemaGraph?
    public private(set) var positions: [String: DiagramPoint] = [:]
    public private(set) var isLoading = false
    public private(set) var error: String?
    public var selected: String?

    private var session: Session

    init(path: [String], session: Session) {
        self.path = path
        self.session = session
    }

    public var title: String { "Relations · \(path.last ?? "")" }

    public func start() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let g = try await session.schemaGraph(path: path)
            graph = g
            positions = Self.layout(g)
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    func rebind(_ session: Session) {
        self.session = session
    }

    public func move(_ table: String, to point: DiagramPoint) {
        positions[table] = DiagramPoint(x: max(0, point.x), y: max(0, point.y))
    }

    public func resetLayout() {
        if let graph { positions = Self.layout(graph) }
    }

    public static func cardHeight(_ table: GraphTable) -> Double {
        let shown = min(table.columns.count, maxRows) + (table.columns.count > maxRows ? 1 : 0)
        return headerHeight + Double(max(shown, 1)) * rowHeight + 8
    }

    /// Where a column's row sits on its card (falls back to the header).
    public func anchorY(table: GraphTable, column: String) -> Double {
        let top = positions[table.name]?.y ?? 0
        guard let i = table.columns.firstIndex(where: { $0.name == column }), i < Self.maxRows else {
            return top + Self.headerHeight / 2
        }
        return top + Self.headerHeight + (Double(i) + 0.5) * Self.rowHeight
    }

    /// The canvas size that fits every card.
    public var canvasSize: (width: Double, height: Double) {
        guard let graph else { return (800, 600) }
        var w = 0.0, h = 0.0
        for t in graph.tables {
            guard let p = positions[t.name] else { continue }
            w = max(w, p.x + Self.cardWidth)
            h = max(h, p.y + Self.cardHeight(t))
        }
        return (w + 80, h + 80)
    }

    /// Tables related to the selected one (to highlight).
    public func isRelatedToSelection(_ relation: Relation) -> Bool {
        guard let selected else { return false }
        return relation.fromTable == selected || relation.toTable == selected
    }

    /// Layered layout: a table's layer is one more than the deepest table it
    /// references, so parents sit left of children. Unrelated tables go in a
    /// grid after the layers.
    static func layout(_ graph: SchemaGraph) -> [String: DiagramPoint] {
        let names = graph.tables.map(\.name)
        let related = Set(graph.relations.flatMap { [$0.fromTable, $0.toTable] })
        var level = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
        // Relax a bounded number of times so cycles can't loop forever.
        for _ in 0..<max(names.count, 1) {
            var changed = false
            for r in graph.relations where r.fromTable != r.toTable {
                let wanted = (level[r.toTable] ?? 0) + 1
                if (level[r.fromTable] ?? 0) < wanted, wanted < names.count {
                    level[r.fromTable] = wanted
                    changed = true
                }
            }
            if !changed { break }
        }
        let byName = Dictionary(uniqueKeysWithValues: graph.tables.map { ($0.name, $0) })
        var out: [String: DiagramPoint] = [:]
        let stride = cardWidth + columnGap
        let layers = Dictionary(grouping: names.filter(related.contains)) { level[$0] ?? 0 }
        var tallest = 0.0
        for (l, members) in layers {
            var y = 40.0
            for name in members.sorted() {
                out[name] = DiagramPoint(x: 40 + Double(l) * stride, y: y)
                y += cardHeight(byName[name]!) + rowGap
            }
            tallest = max(tallest, y)
        }
        // Unrelated tables: a grid to the right, wrapping at the layers' height.
        let lone = names.filter { !related.contains($0) }.sorted()
        var x = 40 + Double(layers.keys.max().map { $0 + 1 } ?? 0) * stride
        var y = 40.0
        let limit = max(tallest, 900)
        for name in lone {
            let h = cardHeight(byName[name]!)
            if y + h > limit, y > 40 {
                x += stride
                y = 40
            }
            out[name] = DiagramPoint(x: x, y: y)
            y += h + rowGap
        }
        return out
    }
}

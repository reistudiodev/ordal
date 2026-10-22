import Foundation

/// Placement and edge routing for the relations diagram. Pure functions, so
/// they are easy to test and the same on every platform.
public enum SchemaLayout {
    public static let cardWidth = 260.0
    public static let headerHeight = 36.0
    public static let rowHeight = 26.0
    static let layerGap = 150.0
    static let rowGap = 40.0
    static let margin = 60.0
    /// Distance between parallel vertical lanes in a gap.
    static let laneSpacing = 10.0

    public static func cardHeight(_ table: GraphTable) -> Double {
        headerHeight + Double(max(table.columns.count, 1)) * rowHeight + 6
    }

    /// Where a column row's centre sits on a card at `top` (header if unknown).
    public static func rowY(_ table: GraphTable, column: String, top: Double) -> Double {
        guard let i = table.columns.firstIndex(where: { $0.name == column }) else { return top + headerHeight / 2 }
        return top + headerHeight + (Double(i) + 0.5) * rowHeight
    }

    // MARK: Layout

    /// Left-to-right layered layout: a table's layer is one more than the
    /// deepest table it references, so referenced tables sit to the left.
    /// Inside a layer, tables are ordered to reduce crossing edges, and each
    /// layer is centred vertically. Unrelated tables go in a grid at the end.
    public static func layout(_ graph: SchemaGraph) -> [String: DiagramPoint] {
        let byName = Dictionary(graph.tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let level = layers(graph)
        let order = orderLayers(graph, level: level)
        let stride = cardWidth + layerGap

        var out: [String: DiagramPoint] = [:]
        let heights = order.map { layer in
            layer.reduce(0.0) { $0 + cardHeight(byName[$1]!) } + Double(max(layer.count - 1, 0)) * rowGap
        }
        let tallest = heights.max() ?? 0
        for (l, layer) in order.enumerated() {
            var y = margin + (tallest - heights[l]) / 2
            for name in layer {
                out[name] = DiagramPoint(x: margin + Double(l) * stride, y: y)
                y += cardHeight(byName[name]!) + rowGap
            }
        }

        let related = Set(level.keys)
        let lone = graph.tables.map(\.name).filter { !related.contains($0) }.sorted()
        var x = margin + Double(order.count) * stride
        var y = margin
        let limit = max(tallest + margin, 1000)
        for name in lone {
            let h = cardHeight(byName[name]!)
            if y + h > limit, y > margin {
                x += stride
                y = margin
            }
            out[name] = DiagramPoint(x: x, y: y)
            y += h + rowGap
        }
        return out
    }

    /// Layer per related table (unrelated tables are absent).
    static func layers(_ graph: SchemaGraph) -> [String: Int] {
        let names = Set(graph.tables.map(\.name))
        let edges = graph.relations.filter { $0.fromTable != $0.toTable && names.contains($0.fromTable) && names.contains($0.toTable) }
        var level: [String: Int] = [:]
        for r in graph.relations where names.contains(r.fromTable) && names.contains(r.toTable) {
            level[r.fromTable] = 0
            level[r.toTable] = 0
        }
        // Relax a bounded number of times so cycles can't loop forever.
        for _ in 0..<max(level.count, 1) {
            var changed = false
            for r in edges {
                let wanted = (level[r.toTable] ?? 0) + 1
                if (level[r.fromTable] ?? 0) < wanted, wanted < level.count {
                    level[r.fromTable] = wanted
                    changed = true
                }
            }
            if !changed { break }
        }
        return level
    }

    /// Tables per layer, ordered by barycenter sweeps (down then up, 4 times).
    static func orderLayers(_ graph: SchemaGraph, level: [String: Int]) -> [[String]] {
        guard let maxLevel = level.values.max() else { return [] }
        var order: [[String]] = Array(repeating: [], count: maxLevel + 1)
        for (name, l) in level.sorted(by: { $0.key < $1.key }) { order[l].append(name) }

        var neighbours: [String: [String]] = [:]
        for r in graph.relations where r.fromTable != r.toTable && level[r.fromTable] != nil && level[r.toTable] != nil {
            neighbours[r.fromTable, default: []].append(r.toTable)
            neighbours[r.toTable, default: []].append(r.fromTable)
        }
        func index() -> [String: Double] {
            var i: [String: Double] = [:]
            for layer in order { for (k, name) in layer.enumerated() { i[name] = Double(k) } }
            return i
        }
        func sweep(_ layers: [Int], towards: (Int, Int) -> Bool) {
            for l in layers {
                let pos = index()
                let bary: [String: Double] = Dictionary(uniqueKeysWithValues: order[l].map { name in
                    let ns = (neighbours[name] ?? []).filter { level[$0].map { towards($0, l) } ?? false }
                    let b = ns.isEmpty ? pos[name]! : ns.map { pos[$0]! }.reduce(0, +) / Double(ns.count)
                    return (name, b)
                })
                order[l].sort { (bary[$0]!, $0) < (bary[$1]!, $1) }
            }
        }
        for _ in 0..<4 {
            sweep(Array(order.indices.dropFirst())) { other, l in other < l }
            sweep(Array(order.indices.dropLast().reversed())) { other, l in other > l }
        }
        return order
    }

    /// Edge crossings between adjacent layers for a given order (used in tests).
    static func crossings(_ graph: SchemaGraph, order: [[String]]) -> Int {
        var layerOf: [String: Int] = [:], pos: [String: Int] = [:]
        for (l, layer) in order.enumerated() { for (k, n) in layer.enumerated() { layerOf[n] = l; pos[n] = k } }
        let segs: [(Int, Int, Int)] = graph.relations.compactMap { r in
            guard let a = layerOf[r.fromTable], let b = layerOf[r.toTable], abs(a - b) == 1 else { return nil }
            let (lo, hi) = a < b ? (r.fromTable, r.toTable) : (r.toTable, r.fromTable)
            return (min(a, b), pos[lo]!, pos[hi]!)
        }
        var count = 0
        for i in segs.indices {
            for j in segs.indices where j > i && segs[i].0 == segs[j].0 {
                if (segs[i].1 - segs[j].1) * (segs[i].2 - segs[j].2) < 0 { count += 1 }
            }
        }
        return count
    }

    // MARK: Routing

    /// One drawn connector: from a referencing column to a referenced column.
    public struct Edge: Identifiable, Equatable {
        public let id: String
        public let relation: String
        public let fromTable: String
        public let fromColumn: String
        public let toTable: String
        public let toColumn: String
        public let inferred: Bool
        /// Axis-aligned polyline: start, lane corners, end.
        public let points: [DiagramPoint]
    }

    /// Routes every column pair of every relation as right-angle connectors.
    /// Each gap between cards gets its own vertical lanes, so parallel edges
    /// don't sit on top of each other.
    public static func route(_ graph: SchemaGraph, positions: [String: DiagramPoint], hidden: Set<String> = []) -> [Edge] {
        let byName = Dictionary(graph.tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        struct Pending {
            var edge: (id: String, r: Relation, fc: String, tc: String)
            var start: DiagramPoint
            var end: DiagramPoint
            /// The gap the lane lives in, or the right-hand side for C-shapes.
            var gapKey: Int
            var gapStart: Double
            var gapEnd: Double
            var cShape: Bool
        }
        var pending: [Pending] = []
        for r in graph.relations {
            guard !hidden.contains(r.fromTable), !hidden.contains(r.toTable),
                  let a = byName[r.fromTable], let b = byName[r.toTable],
                  let pa = positions[a.name], let pb = positions[b.name] else { continue }
            for (i, (fc, tc)) in zip(r.fromColumns, r.toColumns).enumerated() {
                let ya = rowY(a, column: fc, top: pa.y)
                let yb = rowY(b, column: tc, top: pb.y)
                let id = "\(r.name)#\(i)"
                // The vertical lane sits in the gap next to the referenced card,
                // which is free even when the edge spans several layers.
                if a.name != b.name, pa.x + cardWidth + 20 <= pb.x {
                    let gapStart = max(pa.x + cardWidth, pb.x - layerGap)
                    pending.append(Pending(edge: (id, r, fc, tc), start: .init(x: pa.x + cardWidth, y: ya), end: .init(x: pb.x, y: yb),
                                           gapKey: Int(gapStart), gapStart: gapStart, gapEnd: pb.x, cShape: false))
                } else if a.name != b.name, pb.x + cardWidth + 20 <= pa.x {
                    let gapEnd = min(pa.x, pb.x + cardWidth + layerGap)
                    pending.append(Pending(edge: (id, r, fc, tc), start: .init(x: pa.x, y: ya), end: .init(x: pb.x + cardWidth, y: yb),
                                           gapKey: Int(pb.x + cardWidth), gapStart: pb.x + cardWidth, gapEnd: gapEnd, cShape: false))
                } else {
                    // Same column of cards (or a self-reference): out and back on the right.
                    let right = max(pa.x, pb.x) + cardWidth
                    pending.append(Pending(edge: (id, r, fc, tc), start: .init(x: pa.x + cardWidth, y: ya), end: .init(x: pb.x + cardWidth, y: yb),
                                           gapKey: -Int(right), gapStart: right, gapEnd: right + 60, cShape: true))
                }
            }
        }

        var edges: [Edge] = []
        for (_, group) in Dictionary(grouping: pending, by: \.gapKey) {
            // Lanes in vertical order of the edges' midpoints keep them from crossing needlessly.
            let sorted = group.sorted { ($0.start.y + $0.end.y) < ($1.start.y + $1.end.y) }
            let width = max(sorted[0].gapEnd - sorted[0].gapStart, 40)
            let spacing = min(laneSpacing, (width - 32) / Double(max(sorted.count - 1, 1)))
            let first = sorted[0].cShape
                ? sorted[0].gapStart + 24
                : sorted[0].gapStart + (width - spacing * Double(sorted.count - 1)) / 2
            for (k, p) in sorted.enumerated() {
                let laneX = first + Double(k) * spacing
                let points = p.start.y == p.end.y && !p.cShape
                    ? [p.start, p.end]
                    : [p.start, DiagramPoint(x: laneX, y: p.start.y), DiagramPoint(x: laneX, y: p.end.y), p.end]
                edges.append(Edge(id: p.edge.id, relation: p.edge.r.name, fromTable: p.edge.r.fromTable, fromColumn: p.edge.fc,
                                  toTable: p.edge.r.toTable, toColumn: p.edge.tc, inferred: p.edge.r.inferred, points: points))
            }
        }
        return edges.sorted { $0.id < $1.id }
    }
}

/// Dragged card positions, remembered per connection and schema.
public enum DiagramLayoutStore {
    static func key(connection: String, path: [String]) -> String {
        "dbclient.diagram.\(connection).\(path.joined(separator: "/"))"
    }

    public static func load(connection: String, path: [String], defaults: UserDefaults = .standard) -> [String: DiagramPoint] {
        guard let raw = defaults.dictionary(forKey: key(connection: connection, path: path)) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? DiagramPoint(x: $0[0], y: $0[1]) : nil }
    }

    public static func save(_ positions: [String: DiagramPoint], connection: String, path: [String], defaults: UserDefaults = .standard) {
        defaults.set(positions.mapValues { [$0.x, $0.y] }, forKey: key(connection: connection, path: path))
    }

    public static func clear(connection: String, path: [String], defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(connection: connection, path: path))
    }
}

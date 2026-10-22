import DBClientKit
import SwiftUI

/// Tables as draggable cards with their columns, and relations drawn from the
/// referencing column to the referenced one. Inferred MongoDB relations are
/// dashed. Click a card to highlight its relations; double-click to open it.
struct SchemaDiagramView: View {
    let tab: SchemaTabModel
    let workspace: WorkspaceModel
    @State private var zoom: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = tab.error {
                ContentUnavailableView("Could not load relations", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let graph = tab.graph {
                if graph.tables.isEmpty {
                    ContentUnavailableView("No tables here", systemImage: "square.dashed")
                } else {
                    canvas(graph)
                }
            } else {
                ProgressView("Reading relations…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            if let g = tab.graph {
                let inferred = g.relations.filter(\.inferred).count
                Text("\(g.tables.count) tables · \(g.relations.count) relations" + (inferred > 0 ? " (\(inferred) inferred from data)" : ""))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 44)
            Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button("Tidy Up") { tab.resetLayout() }
                .help("Lay the tables out again")
            Button { Task { await tab.start() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload relations")
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s)
        .frame(height: 30)
    }

    private func canvas(_ graph: SchemaGraph) -> some View {
        let size = tab.canvasSize
        let byName = Dictionary(uniqueKeysWithValues: graph.tables.map { ($0.name, $0) })
        let linked = Set(graph.relations.flatMap { r in r.fromColumns.map { "\(r.fromTable)\u{1F}\($0)" } })
        return GeometryReader { viewport in
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for r in graph.relations {
                        guard let from = byName[r.fromTable], let to = byName[r.toTable] else { continue }
                        draw(r, from: from, to: to, in: &ctx)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { tab.selected = nil }

                ForEach(graph.tables, id: \.name) { table in
                    TableCard(table: table, linked: linked, tab: tab) {
                        workspace.openTable(path: table.path, kind: workspace.config.kind == .mongoDb ? .collection : .table)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
            // Keep the diagram at the top-left instead of centred in the viewport.
            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
        }
        }
        .background(.background.secondary)
    }

    private func draw(_ r: Relation, from: GraphTable, to: GraphTable, in ctx: inout GraphicsContext) {
        guard let fp = tab.positions[from.name], let tp = tab.positions[to.name] else { return }
        let w = SchemaTabModel.cardWidth
        let y1 = tab.anchorY(table: from, column: r.fromColumns.first ?? "")
        let y2 = tab.anchorY(table: to, column: r.toColumns.first ?? "")
        var path = Path()
        let start: CGPoint, end: CGPoint
        if from.name == to.name {
            // A self-reference loops out of the right edge.
            start = CGPoint(x: fp.x + w, y: y1)
            end = CGPoint(x: fp.x + w, y: y2)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + 60, y: start.y), control2: CGPoint(x: end.x + 60, y: end.y))
        } else {
            let leftToRight = fp.x > tp.x
            start = CGPoint(x: leftToRight ? fp.x : fp.x + w, y: y1)
            end = CGPoint(x: leftToRight ? tp.x + w : tp.x, y: y2)
            let bend: CGFloat = max(40, abs(end.x - start.x) / 2)
            let dir: CGFloat = leftToRight ? -1 : 1
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + dir * bend, y: start.y), control2: CGPoint(x: end.x - dir * bend, y: end.y))
        }
        let highlighted = tab.isRelatedToSelection(r)
        let color: Color = highlighted ? .accentColor : Color(nsColor: .tertiaryLabelColor)
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: highlighted ? 2 : 1.2, lineCap: .round, dash: r.inferred ? [5, 4] : []))
        // The referenced end gets a dot, the referencing end a short bar.
        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(color))
        ctx.fill(Path(CGRect(x: start.x - 1, y: start.y - 5, width: 2, height: 10)), with: .color(color))
    }
}

private struct TableCard: View {
    let table: GraphTable
    let linked: Set<String>
    let tab: SchemaTabModel
    let open: () -> Void
    @State private var drag: CGSize = .zero

    var body: some View {
        let p = tab.positions[table.name] ?? DiagramPoint(x: 0, y: 0)
        let selected = tab.selected == table.name
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.hairline) {
                Image(systemName: "tablecells").foregroundStyle(.secondary)
                Text(table.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.hairline)
                if let n = table.estimatedRows {
                    Text(Self.compact(n)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.s)
            .frame(height: SchemaTabModel.headerHeight)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))

            ForEach(Array(table.columns.prefix(SchemaTabModel.maxRows).enumerated()), id: \.offset) { _, c in
                HStack(spacing: Space.hairline) {
                    Image(systemName: c.isKey ? "key.fill" : linked.contains("\(table.name)\u{1F}\(c.name)") ? "link" : "circle.fill")
                        .font(.system(size: c.isKey || linked.contains("\(table.name)\u{1F}\(c.name)") ? 9 : 3))
                        .foregroundStyle(c.isKey ? Color.orange : .secondary)
                        .frame(width: 12)
                    Text(c.name).font(.caption.monospaced()).lineLimit(1)
                    Spacer(minLength: Space.hairline)
                    Text(c.typeName).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, Space.s)
                .frame(height: SchemaTabModel.rowHeight)
            }
            if table.columns.count > SchemaTabModel.maxRows {
                Text("+ \(table.columns.count - SchemaTabModel.maxRows) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.s)
                    .frame(height: SchemaTabModel.rowHeight)
            }
        }
        .padding(.bottom, Space.hairline)
        .frame(width: SchemaTabModel.cardWidth, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .offset(x: p.x + drag.width, y: p.y + drag.height)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture { tab.selected = table.name }
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    tab.move(table.name, to: DiagramPoint(x: p.x + v.translation.width, y: p.y + v.translation.height))
                    drag = .zero
                }
        )
        .help("Double-click to open \(table.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(table.name), \(table.columns.count) columns")
        .accessibilityAddTraits(.isButton)
    }

    static func compact(_ n: UInt64) -> String {
        switch n {
        case 1_000_000...: String(format: "~%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "~%.0fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }
}

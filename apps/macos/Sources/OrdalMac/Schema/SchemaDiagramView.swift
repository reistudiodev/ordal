import AppKit
import OrdalKit
import SwiftUI
import UniformTypeIdentifiers

/// Tables as cards with every column, connected column-to-column by
/// right-angle edges, on a zoomable dotted canvas with a minimap and legend.
struct SchemaDiagramView: View {
    let tab: SchemaTabModel
    let workspace: WorkspaceModel
    @State private var controller = CanvasController()
    @State private var findText = ""
    @State private var didFit = false
    @FocusState private var findFocused: Bool
    @AppStorage(AppTheme.diagramKey) private var diagramTheme = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var canvasTheme: AppTheme { AppTheme(rawValue: diagramTheme) ?? .system }

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
                    canvas
                }
            } else {
                ProgressView("Reading relations…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.s) {
            if let g = tab.graph {
                let inferred = g.relations.filter(\.inferred).count
                Text("\(g.tables.count) tables · \(g.relations.count) relations" + (inferred > 0 ? " (\(inferred) inferred)" : ""))
                    .foregroundStyle(.secondary)
            }
            if tab.focusOnly, let s = tab.selected {
                Button("Showing \(s) and related · Show All") { tab.focusOnly = false }
            }
            Spacer()
            TextField("Find table", text: $findText, prompt: Text("Find table"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($findFocused)
                .onSubmit(find)
            Button { controller.zoom(by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
                .keyboardShortcut("-", modifiers: .command)
            Button("\(Int((controller.magnification * 100).rounded()))%") { controller.zoomToActualSize() }
                .monospacedDigit()
                .help("Actual size")
            Button { controller.zoom(by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘+)")
                .keyboardShortcut("=", modifiers: .command)
            Button { fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Zoom to fit (⌘0)")
                .keyboardShortcut("0", modifiers: .command)
            Menu {
                Picker("Diagram appearance", selection: $diagramTheme) {
                    Text("Match App").tag(AppTheme.system.rawValue)
                    Text("Light").tag(AppTheme.light.rawValue)
                    Text("Dark").tag(AppTheme.dark.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: canvasTheme == .system ? "circle.lefthalf.filled" : canvasTheme.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diagram appearance: \(canvasTheme == .system ? "match app" : canvasTheme.label.lowercased())")
            Button("Tidy Up") { tab.resetLayout() }
                .help("Lay the tables out again (forgets moved cards)")
            Button { exportPNG() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export as PNG")
            Button { Task { await tab.start() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload relations")
            // ⌘F focuses the find field.
            Button("") { findFocused = true }.keyboardShortcut("f").hidden().frame(width: 0)
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.s)
        .frame(height: 32)
    }

    // MARK: Canvas

    private var canvas: some View {
        let size = tab.canvasSize
        let contentSize = CGSize(width: size.width, height: size.height)
        return ZStack(alignment: .bottom) {
            ZoomableCanvas(contentSize: contentSize, controller: controller, appearance: canvasTheme.nsAppearance,
                           interaction: interaction) { effective in
                DiagramContent(tab: tab, workspace: workspace, visible: controller.visibleRect, size: effective)
            }
            HStack(alignment: .bottom) {
                Spacer()
                DiagramLegend()
                Spacer()
            }
            .padding(.bottom, Space.m)
            .allowsHitTesting(false)
            Minimap(tab: tab, canvas: contentSize, controller: controller)
                .padding(Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.bottom, Space.xl)
        }
        // Minimap and legend follow the canvas, not the app.
        .environment(\.colorScheme, canvasTheme.colorScheme ?? colorScheme)
        .onAppear {
            guard !didFit else { return }
            didFit = true
            DispatchQueue.main.async { fitAll() }
        }
    }

    /// Mouse handling for the canvas (see `DiagramHostingView`).
    private var interaction: CanvasInteraction {
        CanvasInteraction(
            cardAt: { p in
                guard let name = tab.table(at: DiagramPoint(x: p.x, y: p.y)), let o = tab.positions[name] else { return nil }
                return (name, CGPoint(x: o.x, y: o.y))
            },
            passThrough: { p, _, origin in
                // The header's ⋮ menu belongs to SwiftUI.
                p.x > origin.x + SchemaLayout.cardWidth - 32 && p.y < origin.y + SchemaLayout.headerHeight
            },
            move: { name, origin, persist in
                tab.move(name, to: DiagramPoint(x: origin.x, y: origin.y), persist: persist)
            },
            clickCard: { name, count in
                if count >= 2 {
                    openTable(name)
                } else {
                    tab.selected = tab.selected == name ? nil : name
                }
            },
            clickBackground: {
                tab.selected = nil
                tab.focusOnly = false
            }
        )
    }

    private func openTable(_ name: String) {
        guard let table = tab.graph?.tables.first(where: { $0.name == name }) else { return }
        workspace.openTable(path: table.path, kind: workspace.config.kind == .mongoDb ? .collection : .table)
    }

    private func fitAll() {
        let s = tab.canvasSize
        controller.fit(CGRect(x: 0, y: 0, width: s.width, height: s.height))
    }

    private func find() {
        guard let name = tab.find(findText), let p = tab.positions[name] else { NSSound.beep(); return }
        tab.selected = name
        controller.center(on: CGPoint(x: p.x + SchemaLayout.cardWidth / 2, y: p.y + 120))
    }

    private func exportPNG() {
        guard let data = controller.pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(workspace.config.name) \(tab.path.last ?? "schema").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Everything inside the zoomable canvas: background, dots, edges, cards.
private struct DiagramContent: View {
    let tab: SchemaTabModel
    let workspace: WorkspaceModel
    let visible: CGRect
    /// The canvas size, at least as large as the viewport.
    let size: CGSize
    /// Above this many tables, only cards near the viewport are built.
    static let cullAbove = 150

    var body: some View {
        let _ = tab.version
        let tables = tab.visibleTables
        let shown = tables.count > Self.cullAbove ? tables.filter(isNearViewport) : tables
        let foreignKeys = foreignKeysByTable
        let focus = tab.focusOnly ? tab.selected : nil
        ZStack(alignment: .topLeading) {
            Color(nsColor: DiagramPalette.canvas)
            DotGrid(size: size)
            EdgeLayer(edges: tab.edges, emphasis: tab.emphasis(of:))
                .frame(width: size.width, height: size.height)
            ForEach(shown, id: \.name) { table in
                TableCard(
                    table: table,
                    position: tab.positions[table.name] ?? DiagramPoint(x: 0, y: 0),
                    emphasis: tab.emphasis(ofTable: table.name),
                    hoveredColumn: tab.hovered?.table == table.name ? tab.hovered?.column : nil,
                    foreignKeys: foreignKeys[table.name] ?? [],
                    references: tab.references(of: table.name),
                    isFocusingThis: focus == table.name,
                    actions: actions(for: table)
                )
                .equatable()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var foreignKeysByTable: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for r in tab.graph?.relations ?? [] { out[r.fromTable, default: []].formUnion(r.fromColumns) }
        return out
    }

    private func actions(for table: GraphTable) -> CardActions {
        let kind: NodeKind = workspace.config.kind == .mongoDb ? .collection : .table
        return CardActions(
            open: { workspace.openTable(path: table.path, kind: kind) },
            newQuery: {
                workspace.newQueryTab(text: workspace.starterQuery(path: table.path, kind: kind, detail: nil),
                                      database: workspace.database(for: table.path))
            },
            toggleFocus: {
                if tab.focusOnly && tab.selected == table.name {
                    tab.focusOnly = false
                } else {
                    tab.selected = table.name
                    tab.focusOnly = true
                }
            },
            hide: { tab.hide(table.name) },
            hover: { column in tab.hovered = column.map { (table.name, $0) } }
        )
    }

    private func isNearViewport(_ t: GraphTable) -> Bool {
        guard let p = tab.positions[t.name] else { return false }
        let rect = CGRect(x: p.x, y: p.y, width: SchemaLayout.cardWidth, height: SchemaLayout.cardHeight(t))
        return rect.intersects(visible.insetBy(dx: -400, dy: -400))
    }
}

/// A dot every 24 pt, in both appearances. A shape (not a `Canvas`) so the
/// whole canvas renders, not only the part that was on screen.
private struct DotGrid: View, Equatable {
    let size: CGSize

    var body: some View {
        Path { p in
            var y = 12.0
            while y < size.height {
                var x = 12.0
                while x < size.width {
                    p.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += 24
                }
                y += 24
            }
        }
        .fill(Color(nsColor: DiagramPalette.dots))
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Right-angle connectors with rounded corners, grouped into a few shapes
/// (by emphasis, solid or dashed) so a drag redraws a handful of paths, not
/// one view per edge. Inferred relations are dashed.
private struct EdgeLayer: View {
    let edges: [SchemaLayout.Edge]
    let emphasis: (SchemaLayout.Edge) -> SchemaTabModel.Emphasis

    var body: some View {
        let groups = Dictionary(grouping: edges) { Group(emphasis: emphasis($0), dashed: $0.inferred) }
        ZStack(alignment: .topLeading) {
            // Dimmed first, highlighted last, so highlighted lines sit on top.
            ForEach(Group.drawOrder, id: \.self) { g in
                if let members = groups[g] {
                    let color = Self.color(g.emphasis)
                    EdgeLines(edges: members)
                        .stroke(color, style: StrokeStyle(lineWidth: g.emphasis == .highlighted ? 2 : 1.2, lineCap: .round,
                                                          lineJoin: .round, dash: g.dashed ? [5, 4] : []))
                    EdgeEnds(edges: members).fill(color)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Group: Hashable {
        let emphasis: SchemaTabModel.Emphasis
        let dashed: Bool

        static let drawOrder: [Group] = [SchemaTabModel.Emphasis.dimmed, .normal, .highlighted].flatMap { e in
            [Group(emphasis: e, dashed: false), Group(emphasis: e, dashed: true)]
        }
    }

    static func color(_ e: SchemaTabModel.Emphasis) -> Color {
        switch e {
        case .highlighted: .accentColor
        case .dimmed: Color(nsColor: .tertiaryLabelColor).opacity(0.35)
        case .normal: Color(nsColor: .secondaryLabelColor).opacity(0.7)
        }
    }
}

/// Every polyline of a group in one path, corners rounded with a 6 pt radius.
private struct EdgeLines: Shape {
    let edges: [SchemaLayout.Edge]

    func path(in _: CGRect) -> Path {
        var path = Path()
        for e in edges {
            guard let first = e.points.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for i in 1..<e.points.count {
                let p = CGPoint(x: e.points[i].x, y: e.points[i].y)
                if i < e.points.count - 1 {
                    let next = CGPoint(x: e.points[i + 1].x, y: e.points[i + 1].y)
                    let prev = CGPoint(x: e.points[i - 1].x, y: e.points[i - 1].y)
                    let r = min(6, hypot(p.x - prev.x, p.y - prev.y) / 2, hypot(next.x - p.x, next.y - p.y) / 2)
                    path.addArc(tangent1End: p, tangent2End: next, radius: r)
                } else {
                    path.addLine(to: p)
                }
            }
        }
        return path
    }
}

/// End markers: a dot at the referenced column, a short bar at the referencing one.
private struct EdgeEnds: Shape {
    let edges: [SchemaLayout.Edge]

    func path(in _: CGRect) -> Path {
        var path = Path()
        for e in edges {
            guard let start = e.points.first, let end = e.points.last else { continue }
            path.addEllipse(in: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7))
            path.addRect(CGRect(x: start.x - 1, y: start.y - 5, width: 2, height: 10))
        }
        return path
    }
}

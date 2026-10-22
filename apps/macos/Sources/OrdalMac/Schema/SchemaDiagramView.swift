import AppKit
import DBClientKit
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
        let canvasSize = CGSize(width: size.width, height: size.height)
        return ZStack(alignment: .bottom) {
            ZoomableCanvas(size: canvasSize, controller: controller, appearance: canvasTheme.nsAppearance) {
                DiagramContent(tab: tab, workspace: workspace, visible: controller.visibleRect, size: canvasSize)
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
            HStack(alignment: .bottom) {
                Spacer()
                DiagramLegend()
                Spacer()
            }
            .padding(.bottom, Space.m)
            .allowsHitTesting(false)
            Minimap(tab: tab, canvas: canvasSize, controller: controller)
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

/// Everything inside the zoomable canvas: dots, edges, cards.
private struct DiagramContent: View {
    let tab: SchemaTabModel
    let workspace: WorkspaceModel
    let visible: CGRect
    let size: CGSize
    /// Above this many tables, only cards near the viewport are built.
    static let cullAbove = 150

    var body: some View {
        let _ = tab.version
        let tables = tab.visibleTables
        let shown = tables.count > Self.cullAbove ? tables.filter(isNearViewport) : tables
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { tab.selected = nil; tab.focusOnly = false }
            DotGrid(size: size).allowsHitTesting(false)
            EdgeLayer(tab: tab).frame(width: size.width, height: size.height)
            ForEach(shown, id: \.name) { table in
                TableCard(
                    table: table, tab: tab,
                    isForeignKey: { tab.isForeignKey(table: table.name, column: $0) },
                    open: { workspace.openTable(path: table.path, kind: workspace.config.kind == .mongoDb ? .collection : .table) },
                    newQuery: {
                        let kind: NodeKind = workspace.config.kind == .mongoDb ? .collection : .table
                        workspace.newQueryTab(text: workspace.starterQuery(path: table.path, kind: kind, detail: nil),
                                              database: workspace.database(for: table.path))
                    }
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func isNearViewport(_ t: GraphTable) -> Bool {
        guard let p = tab.positions[t.name] else { return false }
        let rect = CGRect(x: p.x, y: p.y, width: SchemaLayout.cardWidth, height: SchemaLayout.cardHeight(t))
        return rect.intersects(visible.insetBy(dx: -400, dy: -400))
    }
}

/// A dot every 24 pt, in both appearances. A shape (not a `Canvas`) so the
/// whole canvas renders, not only the part that was on screen.
private struct DotGrid: View {
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
        .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.6))
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// Right-angle connectors with rounded corners. Inferred relations are dashed.
/// Drawn as shapes so edges outside the visible area render (and export) too.
private struct EdgeLayer: View {
    let tab: SchemaTabModel

    var body: some View {
        let _ = tab.version
        let edges = tab.edges
        // Highlighted edges last, so they sit on top.
        let ordered = edges.sorted { rank(tab.emphasis(of: $0)) < rank(tab.emphasis(of: $1)) }
        ZStack(alignment: .topLeading) {
            ForEach(ordered) { e in
                let emphasis = tab.emphasis(of: e)
                let color = color(emphasis)
                Self.rounded(e.points)
                    .stroke(color, style: StrokeStyle(lineWidth: emphasis == .highlighted ? 2 : 1.2, lineCap: .round,
                                                      lineJoin: .round, dash: e.inferred ? [5, 4] : []))
                if let end = e.points.last, let start = e.points.first {
                    // Referenced end: a dot. Referencing end: a short bar.
                    Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)).fill(color)
                    Path(CGRect(x: start.x - 1, y: start.y - 5, width: 2, height: 10)).fill(color)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rank(_ e: SchemaTabModel.Emphasis) -> Int {
        switch e {
        case .dimmed: 0
        case .normal: 1
        case .highlighted: 2
        }
    }

    private func color(_ e: SchemaTabModel.Emphasis) -> Color {
        switch e {
        case .highlighted: .accentColor
        case .dimmed: Color(nsColor: .tertiaryLabelColor).opacity(0.35)
        case .normal: Color(nsColor: .secondaryLabelColor).opacity(0.7)
        }
    }

    /// A polyline whose corners are rounded with a 6 pt radius.
    static func rounded(_ points: [DiagramPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for i in 1..<points.count {
            let p = CGPoint(x: points[i].x, y: points[i].y)
            if i < points.count - 1 {
                let next = CGPoint(x: points[i + 1].x, y: points[i + 1].y)
                let prev = CGPoint(x: points[i - 1].x, y: points[i - 1].y)
                let r = min(6, hypot(p.x - prev.x, p.y - prev.y) / 2, hypot(next.x - p.x, next.y - p.y) / 2)
                path.addArc(tangent1End: p, tangent2End: next, radius: r)
            } else {
                path.addLine(to: p)
            }
        }
        return path
    }
}

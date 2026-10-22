import AppKit
import DBClientKit
import SwiftUI

/// Development aid: with `DBCLIENT_SNAPSHOTS=/some/dir` (and usually
/// `DBCLIENT_HOME`), the app drives itself through the main screens against
/// the first saved Postgres connection, writes PNGs of each, measures grid
/// scrolling, and quits. It renders its own windows, so it needs no screen
/// recording permission. Never active in normal use.
@MainActor
enum DevSnapshots {
    static var outputDir: URL? {
        ProcessInfo.processInfo.environment["DBCLIENT_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(app: AppState) async {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String] = []
        mainWindow?.setContentSize(NSSize(width: 1320, height: 820))
        func note(_ s: String) { report.append(s); print("[snapshots] \(s)") }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            await settle()
            capture("welcome-\(suffix)", in: dir)
        }
        NSApp.appearance = NSAppearance(named: .aqua)

        // The connection sheet, once per engine (no servers needed).
        for kind in DatabaseKind.all {
            app.newConnection()
            app.form?.kind = kind
            await settle()
            captureSheet("connect-\(kind)", in: dir)
            app.form = nil
            await settle(0.3)
        }
        for topology in [ConnectionFormModel.MongoTopology.replicaSet, .srv] {
            app.newConnection(url: topology == .srv
                ? "mongodb+srv://ann@cluster0.abcde.mongodb.net/shop"
                : "mongodb://ann:pw@db1:27017,db2:27017/shop?replicaSet=rs0&authSource=admin")
            await settle()
            captureSheet("connect-mongo-\(topology == .srv ? "srv" : "replicaset")", in: dir)
            app.form = nil
            await settle(0.3)
        }

        guard let pg = app.connections.first(where: { $0.kind == .postgres && $0.environment == .local }) else {
            note("no local Postgres connection saved; stopping")
            return finish(report, dir)
        }

        // Connect, browse, open the 1M-row table.
        let t0 = Date()
        await app.connect(pg.id)
        guard let ws = app.activeWorkspace else {
            note("connect failed: \(app.connectError ?? "?")")
            return finish(report, dir)
        }
        note("connect + browse roots: \(ms(since: t0)) ms, server \(ws.serverInfo?.version ?? "?")")
        for path in [[pg.database], [pg.database, "public"], [pg.database, "public", "Tables"]] {
            if let node = ws.browser.node(at: path) { await ws.browser.expand(node) }
        }
        await settle()
        capture("workspace-browser", in: dir)
        captureSidebarList("sidebar-list", in: dir)

        if let table = ws.browser.node(at: [pg.database, "public", "Tables", "events_1m"]) {
            let t1 = Date()
            ws.openTable(table)
            while ws.activeTable?.pager.page == nil { await settle(0.05) }
            guard let tab = ws.activeTable else { return finish(report, dir) }
            let pager = tab.pager
            note("open events_1m, first page: \(ms(since: t1)) ms, count \(pager.count.map { "\($0.exact ? "" : "~")\($0.count)" } ?? "?")")
            await settle()
            capture("table-data", in: dir)

            // Last page of a 1M-row table (keyset), then back one page.
            var t = Date()
            await pager.last()
            note("last page: \(ms(since: t)) ms, rows \(pager.rangeText), page \(pager.pageNumber)")
            t = Date()
            await pager.prev()
            note("previous from last: \(ms(since: t)) ms, rows \(pager.rangeText)")

            // Header sort on an indexed and an unindexed column.
            t = Date()
            await pager.toggleSort(column: "id")
            await pager.toggleSort(column: "id")
            note("sort id desc (indexed): \(ms(since: t)) ms, first id \(pager.row(at: 0)?.cells.first?.cellText ?? "?")")
            t = Date()
            await pager.toggleSort(column: "amount")
            note("sort amount asc (no index): \(ms(since: t)) ms, slow warning: \(pager.sortIsSlow)")
            await settle()
            capture("table-sorted", in: dir)
            await pager.toggleSort(column: "amount")
            await pager.toggleSort(column: "amount")

            // Stage two edits and open the inspector editor and review sheet.
            app.showInspector = true
            if let row = pager.row(at: 1) {
                ws.inspected = .init(column: pager.columns[2], value: row.cells[2], row: 1, columnIndex: 2, tableTab: tab.id)
            }
            pager.stage(row: 1, column: 2, value: .text(v: "renamed"))
            pager.stage(row: 3, column: 4, value: .bool(v: false))
            await settle()
            capture("table-staged", in: dir)
            app.showInspector = false
            await settle(0.3)

            tab.segment = .ddl
            await settle()
            capture("table-ddl", in: dir)
            tab.segment = .query
            await tab.query.run()
            await settle()
            capture("table-query", in: dir)
            tab.segment = .data
            pager.discardEdits()
        } else {
            note("events_1m not found; load scripts/seed-1m.sql")
        }

        // Relations of the public schema.
        ws.openSchema(path: [pg.database, "public"])
        if case .schema(let schema)? = ws.selectedTab {
            while schema.graph == nil && schema.error == nil { await settle(0.05) }
            note("relations: \(schema.graph?.tables.count ?? 0) tables, \(schema.graph?.relations.count ?? 0) relations \(schema.error ?? "")")
            await settle(1.0)
            capture("relations", in: dir)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await settle()
            capture("relations-dark", in: dir)
            NSApp.appearance = NSAppearance(named: .aqua)
            schema.selected = "profiles"
            await settle()
            capture("relations-focused", in: dir)
            schema.focusOnly = true
            await settle()
            capture("relations-focus-only", in: dir)
            schema.focusOnly = false
            schema.selected = nil
            await settle(1.0)
            if let root = mainWindow?.contentView, let scroll = findScroll(root) {
                // The whole canvas as the Export PNG button renders it.
                if let doc = scroll.documentView, let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) {
                    doc.cacheDisplay(in: doc.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("relations-export.png"))
                }
                // Dark appearance with a focused table, captured the same way.
                NSApp.appearance = NSAppearance(named: .darkAqua)
                schema.selected = "profiles"
                await settle(1.0)
                if let doc = scroll.documentView, let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) {
                    doc.cacheDisplay(in: doc.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("relations-export-dark-focused.png"))
                }
                NSApp.appearance = NSAppearance(named: .aqua)
                schema.selected = nil
                // Diagram override: dark canvas inside the light app.
                UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: AppTheme.diagramKey)
                await settle(1.0)
                capture("relations-dark-override-window", in: dir)
                if let doc = scroll.documentView, let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) {
                    doc.cacheDisplay(in: doc.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("relations-dark-override.png"))
                }
                note("canvas appearance with override: \(scroll.effectiveAppearance.name.rawValue), app: \(NSApp.effectiveAppearance.name.rawValue)")
                UserDefaults.standard.removeObject(forKey: AppTheme.diagramKey)
                await settle(0.5)
                note("diagram zoom \(Int(scroll.magnification * 100))%, canvas \(Int(scroll.documentView?.bounds.width ?? 0))x\(Int(scroll.documentView?.bounds.height ?? 0))")
            }
        }

        // A query tab with results.
        let q = ws.newQueryTab(text: "select kind, count(*) as n, sum(amount) as total, max(created_at) as last_seen from events_1m group by kind order by n desc")
        q.format()
        let t2 = Date()
        await q.run()
        note("group-by over 1M rows: \(ms(since: t2)) ms, status \(q.status)")
        await settle()
        capture("query-results", in: dir)
        if let root = mainWindow?.contentView, let tv = findTextView(root) {
            let frame = tv.convert(tv.bounds, to: nil)
            note("editor: \(tv.string.count) chars, window frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)), hidden \(tv.isHiddenOrHasHiddenAncestor)")
            writeView(tv, "editor-only", dir)
        } else {
            note("editor text view not found")
        }

        // Production guard.
        if let prod = app.connections.first(where: { $0.environment == .prod }) {
            await app.connect(prod.id)
            if let pws = app.activeWorkspace, let tab = pws.activeQuery {
                tab.text = "DELETE FROM events_1m"
                await tab.run()
                await settle()
                capture("prod-workspace", in: dir)
                captureSheet("prod-confirm", in: dir)
                note("prod DELETE pending strong confirmation: \(tab.pending?.strong == true)")
                tab.dismissPending()
            }
        }

        // Palette.
        app.showPalette = true
        await settle()
        capture("palette", in: dir)
        app.showPalette = false
        finish(report, dir)
    }

    /// Scrolls the visible grid through the whole table and reports draw times.
    private static func measureScrolling(note: (String) -> Void) async {
        guard let table = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(findTable) }).first,
              let scroll = table.enclosingScrollView else { return note("no grid found") }
        let rows = table.numberOfRows
        let viewport = scroll.contentView.bounds.height
        var frameTimes: [Double] = []
        // 120 jumps spread over the whole table, like a fast fling with the scrollbar.
        for step in 0...120 {
            let y = CGFloat(step) / 120 * (table.bounds.height - viewport)
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.displayIfNeeded()
            frameTimes.append((CACurrentMediaTime() - start) * 1000)
            await settle(0.016)
        }
        let sorted = frameTimes.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100], worst = sorted.last ?? 0
        note(String(format: "scroll %d rows: draw p50 %.1f ms, p95 %.1f ms, max %.1f ms (budget 16.7 ms)", rows, p50, p95, worst))
        let start = Date()
        while table.rows(in: table.visibleRect).length > 0,
              let cell = table.view(atColumn: 0, row: table.rows(in: table.visibleRect).location, makeIfNecessary: false) as? NSTableCellView,
              cell.textField?.stringValue == "…", Date().timeIntervalSince(start) < 5 {
            await settle(0.02)
        }
        note("last page visible after \(ms(since: start)) ms")
    }

    private static func findTextView(_ view: NSView) -> NSTextView? {
        if let t = view as? NSTextView, t.isEditable { return t }
        for sub in view.subviews { if let t = findTextView(sub) { return t } }
        return nil
    }

    private static func writeView(_ view: NSView, _ name: String, _ dir: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return }
        view.cacheDisplay(in: view.visibleRect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func findScroll(_ view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.allowsMagnification { return s }
        for sub in view.subviews { if let s = findScroll(sub) { return s } }
        return nil
    }

    private static func findTable(_ view: NSView) -> NSTableView? {
        if let t = view as? GridTableView { return t }
        for sub in view.subviews { if let t = findTable(sub) { return t } }
        return nil
    }

    private static func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil && $0.frame.width > 400 }
    }

    private static func capture(_ name: String, in dir: URL) {
        guard let window = mainWindow else { return }
        write(window, name, dir)
    }

    /// The sidebar's vibrancy material doesn't render offscreen, so draw its list directly.
    private static func captureSidebarList(_ name: String, in dir: URL) {
        func find(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView, !(t is GridTableView), t.numberOfRows > 0 { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        guard let root = mainWindow?.contentView, let list = find(root) else { return print("[snapshots] no sidebar list") }
        list.appearance = NSAppearance(named: .aqua)
        let rep = list.bitmapImageRepForCachingDisplay(in: list.visibleRect)!
        list.cacheDisplay(in: list.visibleRect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func captureSheet(_ name: String, in dir: URL) {
        guard let sheet = mainWindow?.attachedSheet else { return print("[snapshots] no sheet for \(name)") }
        write(sheet, name, dir)
    }

    private static func write(_ window: NSWindow, _ name: String, _ dir: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func finish(_ report: [String], _ dir: URL) {
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

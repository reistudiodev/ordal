import Foundation
import XCTest
@testable import OrdalKit

@MainActor
final class OrdalKitTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// App state over a temp directory with in-memory passwords and one
    /// saved SQLite connection, already open.
    private func openWorkspace(environment: EnvironmentTag = .local, rows: Int = 3) async throws -> (AppState, WorkspaceModel) {
        let manager = try ConnectionManager.withDirectory(dir: dir.path, useKeychain: false)
        let app = AppState(manager: manager)
        let file = dir.appendingPathComponent("kit.db")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        app.newConnection(url: "sqlite://\(file.path)")
        app.form?.environment = environment
        await app.saveForm(connect: true)
        let ws = try XCTUnwrap(app.activeWorkspace, app.connectError ?? "no workspace")

        let setup = try ws.session.query(query: """
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < \(rows))
            INSERT INTO items SELECT x, 'item ' || x FROM c;
            """, database: nil)
        _ = try await setup.nextPage(maxRows: 1)
        return (app, ws)
    }

    /// Waits until `condition` holds, polling the main actor.
    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Pure helpers

    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("usr", in: "users"))
        XCTAssertNil(Fuzzy.score("xyz", in: "users"))
        XCTAssertEqual(Fuzzy.filter(["order_items", "users", "user_roles"], query: "user", key: { $0 }), ["users", "user_roles"])
    }

    func testSafety() {
        XCTAssertEqual(Safety.decide(kind: .read, environment: .prod, readOnly: false), .run)
        XCTAssertEqual(Safety.decide(kind: .write, environment: .local, readOnly: false), .run)
        guard case .confirm(strong: false, _) = Safety.decide(kind: .write, environment: .prod, readOnly: false) else {
            return XCTFail("prod writes need a confirmation")
        }
        guard case .confirm(strong: true, _) = Safety.decide(kind: .destructive, environment: .prod, readOnly: false) else {
            return XCTFail("prod destructive needs a strong confirmation")
        }
        guard case .blocked = Safety.decide(kind: .ddl, environment: .local, readOnly: true) else {
            return XCTFail("read-only blocks DDL")
        }
    }

    func testSQLFormatter() {
        XCTAssertEqual(
            SQLFormatter.format("select id, count(*) from users u left join orders o on o.user_id = u.id where u.age >= 10 group by id"),
            "SELECT id, count(*)\nFROM users u\nLEFT JOIN orders o ON o.user_id = u.id\nWHERE u.age >= 10\nGROUP BY id"
        )
        XCTAssertEqual(SQLFormatter.format("select 'from x' as a"), "SELECT 'from x' AS a")
        XCTAssertEqual(SQLFormatter.format("select x::int, t.* from t"), "SELECT x::int, t.*\nFROM t")
    }

    func testValueText() {
        XCTAssertEqual(Value.null.cellText, "NULL")
        XCTAssertEqual(Value.float(v: 1.5).cellText, "1.5")
        XCTAssertEqual(Value.bytes(v: Data([0x0a, 0xff])).cellText, "0x0aff")
        XCTAssertEqual(Value.json(v: "{\"b\":1,\"a\":2}").inspectorText, "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
    }

    // MARK: Connection form

    func testFormFromURLKeepsPasswordOutOfConfig() throws {
        let form = ConnectionFormModel()
        form.url = "postgres://ann:s3cret@db.example.com:6543/app"
        XCTAssertEqual(form.kind, .postgres)
        XCTAssertEqual(form.port, "6543")
        XCTAssertEqual(form.password, "s3cret")
        let config = try form.makeConfig()
        XCTAssertEqual(config.host, "db.example.com")
        XCTAssertFalse(String(describing: config).contains("s3cret"))

        form.url = "nonsense"
        XCTAssertNotNil(form.urlError)
    }

    func testFormRejectsBadPort() {
        let form = ConnectionFormModel()
        form.port = "99999"
        XCTAssertEqual(form.problems[.port], "A number from 1 to 65535")
        XCTAssertFalse(form.canSave)
        XCTAssertThrowsError(try form.makeConfig())
    }

    func testEngineDefaultsFollowTheEngine() {
        let form = ConnectionFormModel()
        form.kind = .mySql
        XCTAssertEqual(form.port, "3306")
        form.kind = .redis
        XCTAssertEqual(form.port, "6379")
        XCTAssertEqual(form.database, "0")
        form.port = "7000"
        form.kind = .mongoDb
        XCTAssertEqual(form.port, "7000", "a port the user typed is kept")
        XCTAssertEqual(form.database, "")
    }

    func testSQLiteNeedsAnExistingFileAndNoLogin() throws {
        let form = ConnectionFormModel(kind: .sqlite)
        XCTAssertEqual(form.problems[.file], "Choose a database file")
        form.host = dir.appendingPathComponent("missing.db").path
        XCTAssertNotNil(form.problems[.file])
        try form.createSQLiteFile(at: dir.appendingPathComponent("new.db").path)
        form.username = "ignored"
        form.password = "ignored"
        let config = try form.makeConfig()
        XCTAssertEqual(config.username, "")
        XCTAssertEqual(config.database, "main")
        XCTAssertEqual(config.name, "new.db")
        XCTAssertNil(form.passwordToSave)
    }

    func testMongoTopologies() throws {
        let form = ConnectionFormModel(kind: .mongoDb)
        form.host = "localhost"
        form.authSource = "admin"
        form.directConnection = true
        var config = try form.makeConfig()
        XCTAssertEqual(config.options, ["authSource": "admin", "directConnection": "true"])

        form.mongoTopology = .replicaSet
        form.mongoHosts = "a:27017\nb:27018"
        form.replicaSetName = "rs0"
        config = try form.makeConfig()
        XCTAssertEqual(config.host, "a:27017,b:27018")
        XCTAssertEqual(config.options["replicaSet"], "rs0")
        XCTAssertNil(config.options["directConnection"], "only for a single server")

        form.mongoHosts = "a:27017\nnot-a-port"
        XCTAssertEqual(form.problems[.hosts], "`not-a-port` is not host:port")

        form.mongoTopology = .srv
        form.host = "cluster0.abcde.mongodb.net"
        config = try form.makeConfig()
        XCTAssertEqual(config.options["srv"], "true")
    }

    func testMongoURLFillsTopologyFields() {
        let form = ConnectionFormModel()
        form.url = "mongodb://u:p@a:27017,b:27018/app?replicaSet=rs0&authSource=admin"
        XCTAssertEqual(form.kind, .mongoDb)
        XCTAssertEqual(form.mongoTopology, .replicaSet)
        XCTAssertEqual(form.mongoHosts, "a:27017\nb:27018")
        XCTAssertEqual(form.replicaSetName, "rs0")
        XCTAssertEqual(form.authSource, "admin")
        XCTAssertEqual(form.password, "p")

        form.url = "mongodb+srv://u@cluster0.example.net/app"
        XCTAssertEqual(form.mongoTopology, .srv)
        XCTAssertEqual(form.host, "cluster0.example.net")
    }

    func testRedisDatabaseIndex() throws {
        let form = ConnectionFormModel(kind: .redis)
        form.database = "x"
        XCTAssertNotNil(form.problems[.database])
        form.database = ""
        XCTAssertEqual(try form.makeConfig().database, "0")
    }

    // MARK: Workspace flow

    func testConnectBrowseAndQuery() async throws {
        let (_, ws) = try await openWorkspace()
        XCTAssertEqual(ws.serverInfo?.engine, "SQLite")
        XCTAssertEqual(ws.browser.roots.map(\.name), ["main"])

        let main = try XCTUnwrap(ws.browser.roots.first)
        await ws.browser.expand(main)
        let tables = try XCTUnwrap(main.children?.first { $0.name == "Tables" })
        await ws.browser.expand(tables)
        XCTAssertEqual(tables.children?.map(\.name), ["items"])

        ws.browser.filter = "itm"
        XCTAssertEqual(ws.browser.filtered.map(\.name), ["items"])

        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "SELECT * FROM items ORDER BY id"
        await tab.run()
        XCTAssertEqual(tab.status, .finished)
        XCTAssertEqual(tab.pager?.rowCount, 3)
        XCTAssertEqual(tab.pager?.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(tab.history.first?.query, "SELECT * FROM items ORDER BY id")

        // Clearing history clears in-memory and persisted history to save memory
        tab.clearHistory()
        XCTAssertTrue(tab.history.isEmpty)
        tab.loadHistory()
        XCTAssertTrue(tab.history.isEmpty)
    }

    func testRunSelectionOnly() async throws {
        let (_, ws) = try await openWorkspace()
        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "SELECT 1 AS a;\nSELECT 2 AS b;"
        tab.selection = NSRange(location: 15, length: 14)
        await tab.run()
        XCTAssertEqual(tab.pager?.columns.map(\.name), ["b"])
    }

    func testQueryErrorsShowInTab() async throws {
        let (_, ws) = try await openWorkspace()
        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "SELECT * FROM missing_table"
        await tab.run()
        guard case .failed(let message) = tab.status else { return XCTFail("\(tab.status)") }
        XCTAssertTrue(message.contains("missing_table"))
    }

    func testProductionDestructiveNeedsStrongConfirmation() async throws {
        let (_, ws) = try await openWorkspace(environment: .prod)
        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "DELETE FROM items"
        await tab.run()
        let pending = try XCTUnwrap(tab.pending)
        XCTAssertTrue(pending.strong)
        XCTAssertEqual(tab.status, .idle, "nothing runs before confirming")

        await tab.confirmPending()
        XCTAssertEqual(tab.status, .finished)
        XCTAssertEqual(tab.pager?.rowsAffected, 3)
    }

    func testCursorPagerLoadsAheadAndCaps() async throws {
        let (_, ws) = try await openWorkspace(rows: 5000)
        let cursor = try ws.session.query(query: "SELECT * FROM items", database: nil)
        let pager = CursorPager(cursor: cursor, cap: 2000)
        await pager.start()
        XCTAssertGreaterThanOrEqual(pager.rowCount, 1000, "two pages are loaded ahead")
        XCTAssertLessThan(pager.rowCount, 2000)
        _ = pager.row(at: 900)
        try await eventually("more rows") { pager.rowCount >= 2000 }
        XCTAssertTrue(pager.isTruncated)
        XCTAssertEqual(pager.rowCount, 2000)
    }

    func testTablePagerPagesSortsAndEdits() async throws {
        let (_, ws) = try await openWorkspace(rows: 250)
        let pager = TablePager(session: ws.session, path: ["main", "Tables", "items"])
        await pager.start()
        XCTAssertEqual(pager.count?.count, 250)
        XCTAssertTrue(pager.usesKeyset)
        XCTAssertEqual(pager.rangeText, "1–100")

        await pager.next()
        await pager.next()
        XCTAssertEqual(pager.pageNumber, 3)
        XCTAssertEqual(pager.rowCount, 50)
        XCTAssertFalse(pager.hasNext)
        await pager.prev()
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 101))
        await pager.last()
        XCTAssertEqual(pager.row(at: pager.rowCount - 1)?.cells.first, .int(v: 250))

        // Header sort: descending by id after two clicks.
        await pager.toggleSort(column: "id")
        await pager.toggleSort(column: "id")
        XCTAssertEqual(pager.sort, GridSort(column: "id", descending: true))
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 250))
        await pager.toggleSort(column: "id")
        XCTAssertNil(pager.sort)

        // Stage, see it in the grid, review, apply.
        XCTAssertTrue(pager.canEdit)
        pager.stage(row: 0, column: 1, value: .text(v: "renamed"))
        XCTAssertTrue(pager.isStaged(row: 0, column: 1))
        XCTAssertEqual(pager.row(at: 0)?.cells[1], .text(v: "renamed"))
        let statements = try await pager.previewStatements()
        XCTAssertEqual(statements, [#"UPDATE "main"."items" SET "name" = 'renamed' WHERE "id" = 1"#])
        try await pager.applyEdits()
        XCTAssertTrue(pager.staged.isEmpty)
        XCTAssertEqual(pager.row(at: 0)?.cells[1], .text(v: "renamed"))

        // Setting a cell back to its original value un-stages it.
        pager.stage(row: 1, column: 1, value: .text(v: "x"))
        pager.stage(row: 1, column: 1, value: .text(v: "item 2"))
        XCTAssertTrue(pager.staged.isEmpty)
    }

    func testCursorPagerSortsLoadedRows() async throws {
        let (_, ws) = try await openWorkspace(rows: 20)
        let pager = CursorPager(cursor: try ws.session.query(query: "SELECT id, name FROM items", database: nil))
        await pager.start()
        XCTAssertTrue(pager.canSort)

        // 1st click: Ascending
        pager.toggleSort(column: "id")
        XCTAssertEqual(pager.sort?.column, "id")
        XCTAssertEqual(pager.sort?.descending, false)
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 1))
        XCTAssertEqual(pager.row(at: 19)?.cells.first, .int(v: 20))

        // 2nd click: Descending
        pager.toggleSort(column: "id")
        XCTAssertEqual(pager.sort?.column, "id")
        XCTAssertEqual(pager.sort?.descending, true)
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 20))
        XCTAssertEqual(pager.row(at: 19)?.cells.first, .int(v: 1))

        // Export reflects descending order
        let csv = pager.exportCSV()
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.count > 2)
        XCTAssertTrue(lines[1].starts(with: "20,"))

        // 3rd click: Reset to natural order
        pager.toggleSort(column: "id")
        XCTAssertNil(pager.sort)
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 1))

        // Sort by name descending
        pager.toggleSort(column: "name")
        XCTAssertEqual(pager.sort?.column, "name")
        XCTAssertEqual(pager.sort?.descending, false)
        pager.toggleSort(column: "name")
        XCTAssertEqual(pager.sort?.descending, true)
        XCTAssertEqual(pager.row(at: 0)?.cells[1], .text(v: "item 20"))
        XCTAssertEqual(pager.row(at: 19)?.cells[1], .text(v: "item 1"))
    }

    func testCellValueParser() {
        func meta(_ kind: ValueKind, _ type: String, enums: [String] = []) -> ColumnMeta {
            ColumnMeta(name: "c", typeName: type, kind: kind, nullable: true, isKey: false, hasDefault: false,
                       enumValues: enums, editable: true, indexed: false)
        }
        func ok(_ s: String, _ m: ColumnMeta) -> Value? { try? CellValueParser.parse(s, for: m).get() }
        func err(_ s: String, _ m: ColumnMeta) -> String? {
            if case .failure(let e) = CellValueParser.parse(s, for: m) { return e.message }
            return nil
        }
        XCTAssertEqual(ok("42", meta(.int, "integer")), .int(v: 42))
        XCTAssertEqual(err("40000", meta(.int, "smallint")), "Must be between -32768 and 32767 for smallint")
        XCTAssertEqual(err("-1", meta(.int, "int unsigned")), "Must be between 0 and 4294967295 for int unsigned")
        XCTAssertNotNil(err("4.2", meta(.int, "bigint")))
        XCTAssertEqual(ok("12.34", meta(.decimal, "numeric(5,2)")), .decimal(v: "12.34"))
        XCTAssertEqual(err("12.345", meta(.decimal, "numeric(5,2)")), "At most 2 digits after the point")
        XCTAssertEqual(err("1234.5", meta(.decimal, "numeric(5,2)")), "Too large for numeric(5,2)")
        XCTAssertEqual(ok("2026-02-28", meta(.date, "date")), .date(v: "2026-02-28"))
        XCTAssertNotNil(err("2026-02-30", meta(.date, "date")))
        XCTAssertEqual(ok("2026-01-02 03:04:05+07:00", meta(.timestampTz, "timestamp with time zone")),
                       .timestamp(v: "2026-01-02 03:04:05+07:00", hasTz: true))
        XCTAssertNotNil(err("2026-01-02 03:04:05+07", meta(.timestamp, "timestamp")))
        XCTAssertEqual(ok("TRUE", meta(.bool, "boolean")), .bool(v: true))
        XCTAssertNotNil(err("not-a-uuid", meta(.uuid, "uuid")))
        XCTAssertEqual(ok("{\"a\": 1}", meta(.json, "jsonb")), .json(v: "{\"a\": 1}"))
        XCTAssertNotNil(err("{a: 1}", meta(.json, "jsonb")))
        XCTAssertEqual(err("toolong", meta(.text, "character varying(3)")), "At most 3 characters (7 now)")
        XCTAssertEqual(ok("b", meta(.text, "mood", enums: ["a", "b"])), .text(v: "b"))
        XCTAssertNotNil(err("z", meta(.text, "mood", enums: ["a", "b"])))
        XCTAssertNotNil(err("xyz", meta(.text, "objectId")))
    }

    func testRelationsDiagramLayout() async throws {
        let (_, ws) = try await openWorkspace()
        let setup = try ws.session.query(query: """
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id));
            CREATE TABLE reviews (id INTEGER PRIMARY KEY, book_id INTEGER REFERENCES books(id));
            """, database: nil)
        _ = try await setup.nextPage(maxRows: 1)
        ws.openSchema(path: ["main"])
        guard case .schema(let tab)? = ws.selectedTab else { return XCTFail("no relations tab") }
        try await eventually("graph") { tab.graph != nil }
        XCTAssertEqual(tab.graph?.relations.count, 2)
        // Referenced tables sit left of the tables that point at them.
        let x = { (name: String) in tab.positions[name]?.x ?? -1 }
        XCTAssertLessThan(x("authors"), x("books"))
        XCTAssertLessThan(x("books"), x("reviews"))
        XCTAssertNotNil(tab.positions["items"], "unrelated tables are placed too")
        let authors = try XCTUnwrap(tab.graph?.tables.first { $0.name == "authors" })
        XCTAssertTrue(authors.columns[0].isKey && authors.columns[0].isIdentity, "INTEGER PRIMARY KEY is the rowid")

        // Focus: the selected table's edges are highlighted, the rest dimmed.
        tab.selected = "authors"
        XCTAssertEqual(tab.focusSet, ["authors", "books"])
        let edges = tab.edges
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges.filter { tab.emphasis(of: $0) == .highlighted }.map(\.toTable), ["authors"])
        tab.focusOnly = true
        XCTAssertEqual(Set(tab.visibleTables.map(\.name)), ["authors", "books"])
        XCTAssertEqual(tab.find("rvw"), nil, "reviews is hidden by focus")
        tab.focusOnly = false
        XCTAssertEqual(tab.find("rvw"), "reviews")
    }

    // MARK: Diagram layout (pure)

    private func table(_ name: String, _ columns: [String]) -> GraphTable {
        GraphTable(name: name, path: [name],
                   columns: columns.map { GraphColumn(name: $0, typeName: "int4", isKey: $0 == "id", isIdentity: false, isUnique: false, nullable: $0 != "id") },
                   estimatedRows: nil)
    }

    private func rel(_ from: String, _ fc: [String], _ to: String, _ tc: [String]) -> Relation {
        Relation(name: "\(from)_\(fc.joined())", fromTable: from, fromColumns: fc, toTable: to, toColumns: tc, inferred: false)
    }

    func testLayoutReducesCrossings() {
        // Two parents, two children wired so that alphabetical order crosses.
        let graph = SchemaGraph(
            tables: [table("a_parent", ["id"]), table("b_parent", ["id"]), table("a_child", ["id", "p"]), table("b_child", ["id", "p"])],
            relations: [rel("a_child", ["p"], "b_parent", ["id"]), rel("b_child", ["p"], "a_parent", ["id"])]
        )
        let level = SchemaLayout.layers(graph)
        XCTAssertEqual(level["a_parent"], 0)
        XCTAssertEqual(level["a_child"], 1)
        let alphabetical = [["a_parent", "b_parent"], ["a_child", "b_child"]]
        XCTAssertEqual(SchemaLayout.crossings(graph, order: alphabetical), 1)
        XCTAssertEqual(SchemaLayout.crossings(graph, order: SchemaLayout.orderLayers(graph, level: level)), 0)
    }

    func testRoutesAreOrthogonalAndUseSeparateLanes() {
        let graph = SchemaGraph(
            tables: [table("parent", ["id", "code"]), table("child", ["id", "parent_id", "parent_code"]), table("other", ["id", "parent_id"])],
            relations: [
                rel("child", ["parent_id", "parent_code"], "parent", ["id", "code"]),
                rel("other", ["parent_id"], "parent", ["id"]),
            ]
        )
        let positions = SchemaLayout.layout(graph)
        let edges = SchemaLayout.route(graph, positions: positions)
        XCTAssertEqual(edges.count, 3, "a composite key draws one edge per column pair")
        for e in edges {
            for (p, q) in zip(e.points, e.points.dropFirst()) {
                XCTAssertTrue(p.x == q.x || p.y == q.y, "\(e.id) has a diagonal segment")
            }
            let from = graph.tables.first { $0.name == e.fromTable }!
            let to = graph.tables.first { $0.name == e.toTable }!
            XCTAssertEqual(e.points.first!.y, SchemaLayout.rowY(from, column: e.fromColumn, top: positions[from.name]!.y))
            XCTAssertEqual(e.points.last!.y, SchemaLayout.rowY(to, column: e.toColumn, top: positions[to.name]!.y))
        }
        let lanes = edges.filter { $0.points.count == 4 }.map { $0.points[1].x }
        XCTAssertEqual(Set(lanes).count, lanes.count, "parallel edges get their own lanes")
    }

    func testDiagramHitTestAndLiveMove() async throws {
        let (_, ws) = try await openWorkspace()
        let graph = SchemaGraph(
            tables: [table("parent", ["id"]), table("child", ["id", "parent_id"])],
            relations: [rel("child", ["parent_id"], "parent", ["id"])]
        )
        let defaults = UserDefaults(suiteName: "ordal.tests.\(UUID().uuidString)")!
        let tab = SchemaTabModel(path: ["db"], session: ws.session, graph: graph, defaults: defaults)
        let p = try XCTUnwrap(tab.positions["child"])
        XCTAssertEqual(tab.table(at: DiagramPoint(x: p.x + 10, y: p.y + 10)), "child")
        XCTAssertNil(tab.table(at: DiagramPoint(x: 1, y: 1)), "empty canvas")
        // Rows: header first, then one row per column.
        let rowY = { (i: Double) in p.y + SchemaLayout.headerHeight + (i + 0.5) * SchemaLayout.rowHeight }
        XCTAssertNil(tab.column(at: DiagramPoint(x: p.x + 10, y: p.y + 5)), "header")
        XCTAssertEqual(tab.column(at: DiagramPoint(x: p.x + 10, y: rowY(0)))?.column, "id")
        XCTAssertEqual(tab.column(at: DiagramPoint(x: p.x + 10, y: rowY(1)))?.column, "parent_id")

        // A live drag step moves the card and its edge, without saving.
        let before = tab.edges[0]
        tab.move("child", to: DiagramPoint(x: p.x + 300, y: p.y + 120), persist: false)
        let after = tab.edges[0]
        XCTAssertNotEqual(before.points, after.points)
        let child = graph.tables.first { $0.name == "child" }!
        XCTAssertEqual(after.points.first?.y, SchemaLayout.rowY(child, column: "parent_id", top: p.y + 120))
        let id = ws.session.config().id
        XCTAssertTrue(DiagramLayoutStore.load(connection: id, path: ["db"], defaults: defaults).isEmpty)
        tab.move("child", to: DiagramPoint(x: p.x + 300, y: p.y + 120), persist: true)
        XCTAssertEqual(DiagramLayoutStore.load(connection: id, path: ["db"], defaults: defaults)["child"],
                       DiagramPoint(x: p.x + 300, y: p.y + 120))
    }

    func testDocumentParsingKeepsOrderAndTypes() throws {
        let json = #"{"_id":{"$oid":"65f000000000000000000001"},"zeta":1,"alpha":"x\n\u00e9\ud83d\ude00","when":{"$date":"2026-01-02T03:04:05Z"},"price":{"$numberDecimal":"9.99"},"big":{"$numberLong":"9007199254740993"},"tags":["a",true,null],"nested":{"b":2.5,"a":[]}}"#
        let doc = try XCTUnwrap(DocValue.parse(json))
        guard case .object(let fields) = doc else { return XCTFail("not an object") }
        XCTAssertEqual(fields.map(\.key), ["_id", "zeta", "alpha", "when", "price", "big", "tags", "nested"], "stored order")
        XCTAssertEqual(fields[0].value, .objectId("65f000000000000000000001"))
        XCTAssertEqual(fields[2].value, .string("x\né😀"))
        XCTAssertEqual(fields[3].value, .date("2026-01-02T03:04:05Z"))
        XCTAssertEqual(fields[4].value, .decimal("9.99"))
        XCTAssertEqual(fields[5].value, .long("9007199254740993"), "big integers keep every digit")
        XCTAssertEqual(fields[6].value.preview, "Array (3)")
        XCTAssertEqual(fields[7].value.typeName, "Object")
        XCTAssertTrue(doc.prettyText().contains("\"_id\": ObjectId('65f000000000000000000001')"))
        XCTAssertTrue(doc.prettyText().contains("\"price\": NumberDecimal('9.99')"))
        XCTAssertNil(DocValue.parse("{\"a\": }"))
        // Canonical form keeps exact BSON number types.
        let canonical = try XCTUnwrap(DocValue.parse(#"{"i":{"$numberInt":"34"},"d":{"$numberDouble":"-6.2"},"l":{"$numberLong":"5"}}"#))
        guard case .object(let typed) = canonical else { return XCTFail() }
        XCTAssertEqual(typed.map(\.value.typeName), ["Int32", "Double", "Int64"])
        XCTAssertEqual(DocValue.number("9007199254740993").typeName, "Int64", "relaxed big integers are not Int32")
        XCTAssertEqual(DocValue.parse(#"{"d":{"$date":{"$numberLong":"0"}}}"#), .object([.init(key: "d", value: .date("1970-01-01T00:00:00.000Z"))]))
    }

    func testDiagramPositionsPersist() {
        let defaults = UserDefaults(suiteName: "ordal.tests.\(UUID().uuidString)")!
        DiagramLayoutStore.save(["t": DiagramPoint(x: 10, y: 20)], connection: "c1", path: ["db", "public"], defaults: defaults)
        XCTAssertEqual(DiagramLayoutStore.load(connection: "c1", path: ["db", "public"], defaults: defaults)["t"], DiagramPoint(x: 10, y: 20))
        XCTAssertTrue(DiagramLayoutStore.load(connection: "c2", path: ["db", "public"], defaults: defaults).isEmpty)
        DiagramLayoutStore.clear(connection: "c1", path: ["db", "public"], defaults: defaults)
        XCTAssertTrue(DiagramLayoutStore.load(connection: "c1", path: ["db", "public"], defaults: defaults).isEmpty)
    }

    func testReconnectKeepsTabs() async throws {
        let (_, ws) = try await openWorkspace()
        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "SELECT count(*) FROM items"
        let before = ws.session
        await ws.reconnect()
        XCTAssertEqual(ws.state, .connected)
        XCTAssertFalse(ws.session === before)
        await tab.run()
        XCTAssertEqual(tab.status, .finished)
    }

    func testSaveAndOpenSQLFiles() async throws {
        let (_, ws) = try await openWorkspace()
        let tab = try XCTUnwrap(ws.activeQuery)
        tab.text = "SELECT 1;"
        XCTAssertTrue(tab.isDirty)
        let url = dir.appendingPathComponent("report.sql")
        try tab.save(to: url)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.title, "report")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "SELECT 1;")
        try ws.openFile(url)
        XCTAssertEqual(ws.activeQuery?.text, "SELECT 1;")
        XCTAssertEqual(ws.activeQuery?.fileURL, url)
    }

    func testTableTabStructureAndDDL() async throws {
        let (_, ws) = try await openWorkspace()
        let main = try XCTUnwrap(ws.browser.roots.first)
        await ws.browser.expand(main)
        let tables = try XCTUnwrap(main.children?.first { $0.name == "Tables" })
        await ws.browser.expand(tables)
        ws.openTable(try XCTUnwrap(tables.children?.first))
        let tab = try XCTUnwrap(ws.activeTable)
        XCTAssertEqual(tab.query.text, "SELECT *\nFROM \"items\"\nLIMIT 100;")
        try await eventually("structure") { !tab.structure.isEmpty }
        XCTAssertEqual(tab.structure.map(\.name), ["id", "name"])
        XCTAssertTrue(tab.ddl.contains("PRIMARY KEY (\"id\")"), tab.ddl)
        XCTAssertEqual(ws.starterQuery(for: try XCTUnwrap(tables.children?.first)), "SELECT *\nFROM \"items\"\nLIMIT 100;")
        XCTAssertEqual(WorkspaceModel.redisArg("a key"), "\"a key\"")
        XCTAssertEqual(WorkspaceModel.jsonString("we\"ird"), "\"we\\\"ird\"")
    }

    func testPalette() {
        var ran = ""
        let palette = PaletteModel(commands: [
            PaletteCommand(id: "a", title: "New Query Tab") { ran = "a" },
            PaletteCommand(id: "b", title: "Toggle Inspector") { ran = "b" },
        ])
        palette.query = "insp"
        XCTAssertEqual(palette.results.map(\.id), ["b"])
        XCTAssertTrue(palette.runSelected())
        XCTAssertEqual(ran, "b")
    }

    func testDataExporterCSVAndJSON() {
        let cols = [
            ColumnInfo(name: "id", typeName: "INTEGER", kind: .int),
            ColumnInfo(name: "name", typeName: "TEXT", kind: .text),
            ColumnInfo(name: "meta", typeName: "JSON", kind: .json)
        ]
        let rows = [
            Row(cells: [.int(v: 1), .text(v: "Alice, Developer"), .json(v: "{\"role\":\"admin\"}")]),
            Row(cells: [.int(v: 2), .text(v: "Bob \"The Builder\""), .null])
        ]

        let csv = DataExporter.csv(columns: cols, rows: rows)
        XCTAssertTrue(csv.contains("id,name,meta"))
        XCTAssertTrue(csv.contains("1,\"Alice, Developer\",\"{\"\"role\"\":\"\"admin\"\"}\""))
        XCTAssertTrue(csv.contains("2,\"Bob \"\"The Builder\"\"\""))

        let json = DataExporter.json(columns: cols, rows: rows, pretty: false)
        XCTAssertTrue(json.contains("\"id\":1"))
        XCTAssertTrue(json.contains("\"name\":\"Alice, Developer\""))
        XCTAssertTrue(json.contains("\"role\":\"admin\""))
        XCTAssertTrue(json.contains("\"name\":\"Bob \\\"The Builder\\\"\""))
    }

    func testDataExporterSQLInsertsAndDDL() {
        let cols = [
            ColumnInfo(name: "id", typeName: "INTEGER", kind: .int),
            ColumnInfo(name: "name", typeName: "TEXT", kind: .text),
            ColumnInfo(name: "active", typeName: "BOOLEAN", kind: .bool)
        ]
        let rows = [
            Row(cells: [.int(v: 1), .text(v: "Alice's Pizza"), .bool(v: true)]),
            Row(cells: [.int(v: 2), .text(v: "Bob"), .bool(v: false)])
        ]

        let sql = DataExporter.sqlInserts(table: "users", columns: cols, rows: rows, engine: .postgres, batchSize: 100)
        XCTAssertTrue(sql.contains("INSERT INTO \"users\" (\"id\", \"name\", \"active\") VALUES"))
        XCTAssertTrue(sql.contains("(1, 'Alice''s Pizza', TRUE)"))
        XCTAssertTrue(sql.contains("(2, 'Bob', FALSE)"))

        let meta = TableMeta(
            columns: [
                ColumnMeta(name: "id", typeName: "integer", kind: .int, nullable: false, isKey: true, hasDefault: false, enumValues: [], editable: false, indexed: true),
                ColumnMeta(name: "email", typeName: "text", kind: .text, nullable: false, isKey: false, hasDefault: false, enumValues: [], editable: true, indexed: true)
            ],
            paging: .keyset,
            keyColumns: ["id"],
            editable: true,
            readOnlyReason: nil
        )

        let ddl = DataExporter.createTableDDL(table: "users", meta: meta, engine: .postgres)
        XCTAssertTrue(ddl.contains("CREATE TABLE \"users\" ("))
        XCTAssertTrue(ddl.contains("\"id\" integer NOT NULL"))
        XCTAssertTrue(ddl.contains("\"email\" text NOT NULL"))
        XCTAssertTrue(ddl.contains("PRIMARY KEY (\"id\")"))

        let mongoScript = DataExporter.mongoCollectionScript(
            collection: "customers",
            indexes: [BrowseNode(name: "email_1", kind: .index, hasChildren: false, detail: "unique: true")],
            rows: [Row(cells: [.json(v: "{\"_id\":\"123\",\"name\":\"Alice\"}")])],
            includeStructure: true,
            includeData: true
        )
        XCTAssertTrue(mongoScript.contains("db.createCollection(\"customers\");"))
        XCTAssertTrue(mongoScript.contains("db.customers.insertMany(["))
        XCTAssertTrue(mongoScript.contains("{\"_id\":\"123\",\"name\":\"Alice\"}"))
    }

    func testDatabaseExporterSingleTableAndDatabase() async throws {
        let (_, ws) = try await openWorkspace(rows: 2)

        // 1. Find exportable relations in sqlite database "main"
        let relations = try await ExportService.findExportableRelations(session: ws.session, rootPath: ["main"])
        XCTAssertTrue(relations.contains { $0.name == "items" && $0.kind == .table })

        // 2. Export single table: Structure only
        let targetTable = ExportTarget(name: "items", path: ["main", "Tables", "items"], kind: .table)
        let structureOnlyOpts = ExportOptions(content: .structureOnly, format: .sql, limit: .hundred)
        let structureSQL = try await ExportService.export(session: ws.session, engine: .sqlite, target: targetTable, options: structureOnlyOpts)
        XCTAssertTrue(structureSQL.contains("CREATE TABLE \"items\""))
        XCTAssertFalse(structureSQL.contains("INSERT INTO"))

        // 3. Export single table: Data only
        let dataOnlyOpts = ExportOptions(content: .dataOnly, format: .sql, limit: .hundred)
        let dataSQL = try await ExportService.export(session: ws.session, engine: .sqlite, target: targetTable, options: dataOnlyOpts)
        XCTAssertFalse(dataSQL.contains("CREATE TABLE"))
        XCTAssertTrue(dataSQL.contains("INSERT INTO \"items\""))
        XCTAssertTrue(dataSQL.contains("'item 1'"))

        // 4. Export single table: Both (Structure + Data)
        let bothOpts = ExportOptions(content: .both, format: .sql, limit: .hundred)
        let bothSQL = try await ExportService.export(session: ws.session, engine: .sqlite, target: targetTable, options: bothOpts)
        XCTAssertTrue(bothSQL.contains("CREATE TABLE \"items\""))
        XCTAssertTrue(bothSQL.contains("INSERT INTO \"items\""))

        // 5. Export entire database "main": Both (Full Backup)
        let targetDB = ExportTarget(name: "main", path: ["main"], kind: .database)
        let dbBackupSQL = try await ExportService.export(session: ws.session, engine: .sqlite, target: targetDB, options: bothOpts)
        XCTAssertTrue(dbBackupSQL.contains("Database / Schema Backup: main"))
        XCTAssertTrue(dbBackupSQL.contains("Object: items (table)"))
        XCTAssertTrue(dbBackupSQL.contains("CREATE TABLE \"items\""))
        XCTAssertTrue(dbBackupSQL.contains("INSERT INTO \"items\""))

        // 6. Export database as JSON
        let dbJSONOpts = ExportOptions(content: .both, format: .json, limit: .hundred)
        let dbJSON = try await ExportService.export(session: ws.session, engine: .sqlite, target: targetDB, options: dbJSONOpts)
        XCTAssertTrue(dbJSON.contains("\"database\" : \"main\""))
        XCTAssertTrue(dbJSON.contains("\"items\" : {"))
        XCTAssertTrue(dbJSON.contains("\"data\" : ["))
    }

    func testSchemaManagerRename() async throws {
        // 1. Verify SQL generation for each engine
        let sqliteTarget = RenameTarget(name: "items", path: ["main", "Tables", "items"], kind: .table)
        let (sqliteSQL, _) = try SchemaManager.renameSQL(engine: .sqlite, target: sqliteTarget, newName: "products")
        XCTAssertEqual(sqliteSQL, "ALTER TABLE \"items\" RENAME TO \"products\";")

        let pgTarget = RenameTarget(name: "items", path: ["app_db", "public", "Tables", "items"], kind: .table)
        let (pgSQL, pgDB) = try SchemaManager.renameSQL(engine: .postgres, target: pgTarget, newName: "products")
        XCTAssertEqual(pgSQL, "ALTER TABLE \"public\".\"items\" RENAME TO \"products\";")
        XCTAssertEqual(pgDB, "app_db")

        let mySqlTarget = RenameTarget(name: "items", path: ["app_db", "Tables", "items"], kind: .table)
        let (mySqlSQL, _) = try SchemaManager.renameSQL(engine: .mySql, target: mySqlTarget, newName: "products")
        XCTAssertEqual(mySqlSQL, "RENAME TABLE `items` TO `products`;")

        let mongoTarget = RenameTarget(name: "customers", path: ["mydb", "customers"], kind: .collection)
        let (mongoCmd, mongoDB) = try SchemaManager.renameSQL(engine: .mongoDb, target: mongoTarget, newName: "clients")
        XCTAssertEqual(mongoCmd, "{\"renameCollection\": \"mydb.customers\", \"to\": \"mydb.clients\"}")
        XCTAssertEqual(mongoDB, "admin")

        // 2. Test live rename in SQLite workspace
        let (_, ws) = try await openWorkspace(rows: 3)
        let target = RenameTarget(name: "items", path: ["main", "Tables", "items"], kind: .table)

        // Open table tab before rename
        ws.openTable(path: target.path, kind: .table)
        let tableTab = try XCTUnwrap(ws.activeTable)
        XCTAssertEqual(tableTab.title, "items")

        // Execute rename to "inventory"
        try await ws.renameNode(target: target, to: "inventory")

        // Verify open tab updated its path and title seamlessly
        XCTAssertEqual(tableTab.title, "inventory")
        XCTAssertEqual(tableTab.path, ["main", "Tables", "inventory"])

        // Verify querying new table name returns data
        let queryTab = ws.newQueryTab(text: "SELECT * FROM inventory")
        await queryTab.run()
        XCTAssertEqual(queryTab.status, .finished)
        XCTAssertEqual(queryTab.pager?.rowCount, 3)
    }

    func testSQLTypeCatalogAndAlterColumnType() async throws {
        // 1. Verify SQLTypeCatalog categories and types
        let pgCategories = SQLTypeCatalog.categories(for: .postgres)
        XCTAssertTrue(pgCategories.contains { $0.id == "text" })
        XCTAssertTrue(pgCategories.contains { $0.id == "boolean" })
        let pgTypes = SQLTypeCatalog.allTypes(for: .postgres)
        XCTAssertTrue(pgTypes.contains("VARCHAR(255)"))
        XCTAssertTrue(pgTypes.contains("BOOLEAN"))
        XCTAssertTrue(pgTypes.contains("JSONB"))

        let mySqlTypes = SQLTypeCatalog.allTypes(for: .mySql)
        XCTAssertTrue(mySqlTypes.contains("VARCHAR(255)"))
        XCTAssertTrue(mySqlTypes.contains("TINYINT(1)"))

        let sqliteTypes = SQLTypeCatalog.allTypes(for: .sqlite)
        XCTAssertTrue(sqliteTypes.contains("TEXT"))
        XCTAssertTrue(sqliteTypes.contains("INTEGER"))
        XCTAssertTrue(sqliteTypes.contains("BOOLEAN"))

        // 2. Verify SQL Generation
        let (pgSQL, pgDB) = try SchemaManager.alterColumnTypeSQL(
            engine: .postgres,
            path: ["mydb", "public", "Tables", "users"],
            column: "active",
            newType: "BOOLEAN"
        )
        XCTAssertEqual(pgSQL, "ALTER TABLE \"public\".\"users\" ALTER COLUMN \"active\" TYPE BOOLEAN USING \"active\"::BOOLEAN;")
        XCTAssertEqual(pgDB, "mydb")

        let (mySqlSQL, mySqlDB) = try SchemaManager.alterColumnTypeSQL(
            engine: .mySql,
            path: ["mydb", "Tables", "users"],
            column: "active",
            newType: "BOOLEAN"
        )
        XCTAssertEqual(mySqlSQL, "ALTER TABLE `users` MODIFY COLUMN `active` BOOLEAN;")
        XCTAssertEqual(mySqlDB, "mydb")

        // 3. Test altering column type in live SQLite database
        let (_, ws) = try await openWorkspace(rows: 2)
        let setup = try ws.session.query(query: """
            CREATE TABLE products (id INTEGER PRIMARY KEY, title TEXT, price TEXT);
            INSERT INTO products VALUES (1, 'Widget', '49.99'), (2, 'Gadget', '99.50');
            """, database: nil)
        _ = try await setup.nextPage(maxRows: 1)

        let target = ColumnTypeTarget(
            column: "price",
            currentType: "TEXT",
            tablePath: ["main", "Tables", "products"],
            tableName: "products"
        )

        ws.openTable(path: target.tablePath, kind: .table)
        let tab = try XCTUnwrap(ws.activeTable)
        try await eventually("structure loaded") { !tab.structure.isEmpty }
        let initialCol = try XCTUnwrap(tab.structure.first { $0.name == "price" })
        XCTAssertEqual(initialCol.detail, "text")

        // Change column "price" from TEXT to REAL
        try await ws.changeColumnType(target: target, newType: "REAL")

        // Verify structure updated
        try await eventually("type updated to real") {
            tab.structure.first { $0.name == "price" }?.detail == "real"
        }

        // Verify data preserved
        XCTAssertEqual(tab.pager.rowCount, 2)
        let row1 = try XCTUnwrap(tab.pager.row(at: 0))
        XCTAssertEqual(row1.cells[1], .text(v: "Widget"))
        if case .float(let val) = row1.cells[2] {
            XCTAssertEqual(val, 49.99, accuracy: 0.01)
        } else {
            XCTFail("Expected float value for price, got \(row1.cells[2])")
        }
    }
}

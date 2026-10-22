import Foundation
import XCTest
@testable import DBClientKit

@MainActor
final class DBClientKitTests: XCTestCase {
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
        pager.toggleSort(column: "id")
        pager.toggleSort(column: "id")
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 20))
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
}

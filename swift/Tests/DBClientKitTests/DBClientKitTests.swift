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
        XCTAssertThrowsError(try form.makeConfig())
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

    func testWindowPagerRandomAccessKeepsMemoryBounded() async throws {
        let (_, ws) = try await openWorkspace(rows: 30_000)
        let pager = WindowPager(session: ws.session, path: ["main", "Tables", "items"])
        await pager.start()
        XCTAssertEqual(pager.rowCount, 30_000)
        XCTAssertEqual(pager.row(at: 0)?.cells.first, .int(v: 1))

        // Jump to the end without loading anything in between.
        XCTAssertNil(pager.row(at: 29_999))
        try await eventually("last page") { pager.row(at: 29_999) != nil }
        XCTAssertEqual(pager.row(at: 29_999)?.cells.first, .int(v: 30_000))

        // Touch every page; only the most recent ones stay loaded.
        for page in 0..<(30_000 / WindowPager.pageSize) {
            _ = pager.row(at: page * WindowPager.pageSize)
            try await eventually("page \(page)") { pager.row(at: page * WindowPager.pageSize) != nil }
        }
        XCTAssertLessThanOrEqual(pager.loadedPageCount, WindowPager.keptPages)
    }

    func testTableTabStructureAndDDL() async throws {
        let (_, ws) = try await openWorkspace()
        let main = try XCTUnwrap(ws.browser.roots.first)
        await ws.browser.expand(main)
        let tables = try XCTUnwrap(main.children?.first { $0.name == "Tables" })
        await ws.browser.expand(tables)
        ws.openTable(try XCTUnwrap(tables.children?.first))
        let tab = try XCTUnwrap(ws.activeTable)
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

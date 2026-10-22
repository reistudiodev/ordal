import Foundation
import XCTest
@testable import OrdalCore

final class OrdalCoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A manager that keeps passwords in memory, never in the real keychain.
    private func makeManager() throws -> ConnectionManager {
        try ConnectionManager.withDirectory(dir: dir.path, useKeychain: false)
    }

    /// A saved SQLite connection to a fresh, empty database file.
    private func sqliteConnection(_ manager: ConnectionManager, readOnly: Bool = false) throws -> ConnectionConfig {
        let file = dir.appendingPathComponent("test.db")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        var config = try parseConnectionUrl(url: "sqlite://\(file.path)").config
        config.readOnly = readOnly
        return try manager.save(config: config, password: nil)
    }

    func testCoreVersion() {
        XCTAssertFalse(coreVersion().isEmpty)
    }

    func testParseConnectionUrl() throws {
        let parsed = try parseConnectionUrl(url: "postgres://alice:secret@db.local:6543/app?sslmode=require")
        XCTAssertEqual(parsed.config.kind, .postgres)
        XCTAssertEqual(parsed.config.host, "db.local")
        XCTAssertEqual(parsed.config.port, 6543)
        XCTAssertEqual(parsed.config.tls, .require)
        XCTAssertEqual(parsed.password, "secret")
        XCTAssertThrowsError(try parseConnectionUrl(url: "ftp://nope"))
    }

    func testClassify() {
        XCTAssertEqual(classifyStatement(sql: "select 1"), .read)
        XCTAssertEqual(classifyStatement(sql: "delete from t"), .destructive)
    }

    func testSaveListDelete() throws {
        let manager = try makeManager()
        let saved = try sqliteConnection(manager)
        XCTAssertFalse(saved.id.isEmpty)
        XCTAssertEqual(manager.list(), [saved])
        try manager.delete(id: saved.id)
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testSqliteQueryThroughBindings() async throws {
        let manager = try makeManager()
        let saved = try sqliteConnection(manager)
        let info = try await manager.test(config: saved, password: nil)
        XCTAssertEqual(info.engine, "SQLite")

        let session = try await manager.open(id: saved.id)
        let setup = try session.query(query: "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a'), ('b'), ('c')", database: nil)
        _ = try await setup.nextPage(maxRows: 10)

        let cursor = try session.query(query: "SELECT id, name FROM t ORDER BY id", database: nil)
        let columns = try await cursor.columns()
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(columns.first?.kind, .int)

        var rows: [Row] = []
        while true {
            let page = try await cursor.nextPage(maxRows: 2)
            XCTAssertLessThanOrEqual(page.rows.count, 2)
            rows += page.rows
            if page.done { break }
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].cells, [.int(v: 1), .text(v: "a")])

        let tables = try await session.listChildren(path: ["main", "Tables"])
        XCTAssertEqual(tables.map(\.name), ["t"])
        let page = try await session.fetchPage(path: ["main", "Tables", "t"], cursor: .first, size: 2, sort: nil)
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertTrue(page.hasNext)
        let next = try await session.fetchPage(path: ["main", "Tables", "t"], cursor: .after(key: page.lastKey!), size: 2, sort: nil)
        XCTAssertEqual(next.rows.first?.cells.first, .int(v: 3))
        await session.close()
    }

    func testReadOnlyBlocksWrites() async throws {
        let manager = try makeManager()
        let saved = try sqliteConnection(manager, readOnly: true)
        let session = try await manager.open(id: saved.id)
        XCTAssertThrowsError(try session.query(query: "DROP TABLE t", database: nil)) { error in
            guard case CoreError.ReadOnly = error else { return XCTFail("\(error)") }
        }
    }

    func testQueryErrorsSurfaceOnNextPage() async throws {
        let manager = try makeManager()
        let session = try await manager.open(id: try sqliteConnection(manager).id)
        let cursor = try session.query(query: "SELEC nonsense", database: nil)
        do {
            _ = try await cursor.nextPage(maxRows: 10)
            XCTFail("expected an error")
        } catch let error as CoreError {
            guard case .Query = error else { return XCTFail("\(error)") }
        }
    }
}

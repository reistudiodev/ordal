import XCTest
@testable import DBClientCore

final class DBClientCoreTests: XCTestCase {
    func testGreet() {
        XCTAssertTrue(greet(name: "tests").contains("Rust core is alive"))
    }

    func testAddAndListConnections() throws {
        let manager = ConnectionManager()
        try manager.add(config: ConnectionConfig(
            name: "local", kind: .postgres, host: "localhost",
            port: 5432, database: "postgres", username: "postgres"
        ))
        XCTAssertEqual(manager.list().count, 1)
    }
}

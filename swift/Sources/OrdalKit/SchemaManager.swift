import Foundation

/// Defines an object to rename in the database schema.
public struct RenameTarget: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case table = "Table"
        case view = "View"
        case collection = "Collection"
        case database = "Database"
        case schema = "Schema"
    }

    public let id: String
    public let name: String
    public let path: [String]
    public let kind: Kind

    public init(name: String, path: [String], kind: Kind) {
        self.id = path.joined(separator: "/")
        self.name = name
        self.path = path
        self.kind = kind
    }

    public var kindText: String { kind.rawValue }
}

public enum SchemaError: LocalizedError, Sendable {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let msg), .unsupported(let msg): return msg
        }
    }
}

/// Service that constructs and executes schema modification DDL and commands (e.g. rename table, view, collection, schema, database).
public enum SchemaManager {
    /// Generates the appropriate DDL or command query and target database.
    public static func renameSQL(
        engine: DatabaseKind,
        target: RenameTarget,
        newName: String
    ) throws -> (sql: String, database: String?) {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else {
            throw SchemaError.invalid("New name cannot be empty")
        }

        let p = target.path

        switch (engine, target.kind) {
        case (.postgres, .table):
            // path: [db, schema, "Tables", table]
            let schema = p.count >= 2 ? p[1] : "public"
            let db = p.first
            let qSchema = DataExporter.quoteIdentifier(schema, engine: engine)
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("ALTER TABLE \(qSchema).\(qOld) RENAME TO \(qNew);", db)

        case (.postgres, .view):
            let schema = p.count >= 2 ? p[1] : "public"
            let db = p.first
            let qSchema = DataExporter.quoteIdentifier(schema, engine: engine)
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("ALTER VIEW \(qSchema).\(qOld) RENAME TO \(qNew);", db)

        case (.postgres, .schema):
            let db = p.first
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("ALTER SCHEMA \(qOld) RENAME TO \(qNew);", db)

        case (.postgres, .database):
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("ALTER DATABASE \(qOld) RENAME TO \(qNew);", "postgres")

        case (.mySql, .table), (.mySql, .view):
            // path: [db, "Tables", table]
            let db = p.first
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("RENAME TABLE \(qOld) TO \(qNew);", db)

        case (.mySql, .database):
            throw SchemaError.unsupported("MySQL does not support direct database renaming. Please create a new database and migrate your tables.")

        case (.sqlite, .table):
            let qOld = DataExporter.quoteIdentifier(target.name, engine: engine)
            let qNew = DataExporter.quoteIdentifier(trimmedNew, engine: engine)
            return ("ALTER TABLE \(qOld) RENAME TO \(qNew);", nil)

        case (.sqlite, .view):
            throw SchemaError.unsupported("SQLite does not support direct view renaming. Please recreate the view with the new name.")

        case (.sqlite, .database):
            throw SchemaError.unsupported("SQLite databases cannot be renamed via SQL because the database name is bound to the file path on disk.")

        case (.mongoDb, .collection):
            // path: [db, coll]
            let db = p.first ?? "test"
            let cmd = "{\"renameCollection\": \"\(db).\(target.name)\", \"to\": \"\(db).\(trimmedNew)\"}"
            return (cmd, "admin")

        case (.mongoDb, .database):
            throw SchemaError.unsupported("MongoDB does not support direct database renaming. Please copy collections to the new database.")

        default:
            throw SchemaError.unsupported("Renaming \(target.kind.rawValue) is not supported for \(engine.label).")
        }
    }

    /// Executes the rename operation on the session.
    public static func executeRename(
        session: Session,
        engine: DatabaseKind,
        target: RenameTarget,
        newName: String
    ) async throws {
        let (query, database) = try renameSQL(engine: engine, target: target, newName: newName)
        let cursor = try session.query(query: query, database: database)
        _ = try await cursor.nextPage(maxRows: 1)
    }

    /// Generates DDL to alter a column's data type.
    public static func alterColumnTypeSQL(
        engine: DatabaseKind,
        path: [String],
        column: String,
        newType: String,
        tableMeta: TableMeta? = nil
    ) throws -> (sql: String, database: String?) {
        let trimmedType = newType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty else {
            throw SchemaError.invalid("New column type cannot be empty")
        }
        guard let tableName = path.last, !tableName.isEmpty else {
            throw SchemaError.invalid("Table path is invalid")
        }

        switch engine {
        case .postgres:
            let schema = path.count >= 2 ? path[1] : "public"
            let db = path.first
            let qSchema = DataExporter.quoteIdentifier(schema, engine: .postgres)
            let qTable = DataExporter.quoteIdentifier(tableName, engine: .postgres)
            let qCol = DataExporter.quoteIdentifier(column, engine: .postgres)
            let sql = "ALTER TABLE \(qSchema).\(qTable) ALTER COLUMN \(qCol) TYPE \(trimmedType) USING \(qCol)::\(trimmedType);"
            return (sql, db)

        case .mySql:
            let db = path.first
            let qTable = DataExporter.quoteIdentifier(tableName, engine: .mySql)
            let qCol = DataExporter.quoteIdentifier(column, engine: .mySql)
            let sql = "ALTER TABLE \(qTable) MODIFY COLUMN \(qCol) \(trimmedType);"
            return (sql, db)

        case .sqlite:
            let qTable = DataExporter.quoteIdentifier(tableName, engine: .sqlite)
            let qOldTable = DataExporter.quoteIdentifier("\(tableName)_old", engine: .sqlite)
            guard let meta = tableMeta, !meta.columns.isEmpty else {
                throw SchemaError.unsupported("SQLite requires table column metadata to alter column types.")
            }
            var newColDefs: [String] = []
            var colNames: [String] = []
            for col in meta.columns {
                let q = DataExporter.quoteIdentifier(col.name, engine: .sqlite)
                colNames.append(q)
                if col.name == column {
                    var def = "\(q) \(trimmedType)"
                    if col.isKey { def += " PRIMARY KEY" }
                    if !col.nullable { def += " NOT NULL" }
                    newColDefs.append(def)
                } else {
                    var def = "\(q) \(col.typeName)"
                    if col.isKey { def += " PRIMARY KEY" }
                    if !col.nullable { def += " NOT NULL" }
                    newColDefs.append(def)
                }
            }
            let colsList = colNames.joined(separator: ", ")
            let newColsList = newColDefs.joined(separator: ", ")
            let sql = """
            ALTER TABLE \(qTable) RENAME TO \(qOldTable);
            CREATE TABLE \(qTable) (\(newColsList));
            INSERT INTO \(qTable) (\(colsList)) SELECT \(colsList) FROM \(qOldTable);
            DROP TABLE \(qOldTable);
            """
            return (sql, nil)

        default:
            throw SchemaError.unsupported("Changing column types is only supported for SQL databases (PostgreSQL, MySQL, SQLite).")
        }
    }

    /// Executes the alter column type operation on the session.
    public static func alterColumnType(
        session: Session,
        engine: DatabaseKind,
        path: [String],
        column: String,
        newType: String,
        tableMeta: TableMeta? = nil
    ) async throws {
        let (query, database) = try alterColumnTypeSQL(
            engine: engine,
            path: path,
            column: column,
            newType: newType,
            tableMeta: tableMeta
        )
        let cursor = try session.query(query: query, database: database)
        _ = try await cursor.nextPage(maxRows: 1)
    }
}

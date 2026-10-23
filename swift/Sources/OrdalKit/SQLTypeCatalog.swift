import Foundation
import OrdalCore

/// Represents a categorized group of SQL data types.
public struct SQLTypeCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let types: [String]

    public init(id: String, name: String, types: [String]) {
        self.id = id
        self.name = name
        self.types = types
    }
}

/// Target column information for altering data type.
public struct ColumnTypeTarget: Identifiable, Sendable, Equatable {
    public let column: String
    public let currentType: String
    public let tablePath: [String]
    public let tableName: String
    public var id: String { "\(tableName).\(column)" }

    public init(column: String, currentType: String, tablePath: [String], tableName: String) {
        self.column = column
        self.currentType = currentType
        self.tablePath = tablePath
        self.tableName = tableName
    }
}

/// Provides available SQL data types by category for each database engine.
public enum SQLTypeCatalog {
    public static func categories(for engine: DatabaseKind) -> [SQLTypeCategory] {
        switch engine {
        case .postgres:
            return [
                SQLTypeCategory(id: "text", name: "Text / String", types: [
                    "VARCHAR(255)", "TEXT", "VARCHAR(50)", "VARCHAR(100)", "VARCHAR(500)", "CHAR(10)", "CHAR(50)"
                ]),
                SQLTypeCategory(id: "integer", name: "Integer", types: [
                    "INTEGER", "BIGINT", "SMALLINT"
                ]),
                SQLTypeCategory(id: "decimal", name: "Decimal / Numeric", types: [
                    "DECIMAL(10, 2)", "NUMERIC(12, 4)", "DOUBLE PRECISION", "REAL"
                ]),
                SQLTypeCategory(id: "boolean", name: "Boolean", types: [
                    "BOOLEAN"
                ]),
                SQLTypeCategory(id: "datetime", name: "Date & Time", types: [
                    "TIMESTAMP", "TIMESTAMPTZ", "DATE", "TIME", "INTERVAL"
                ]),
                SQLTypeCategory(id: "json_uuid", name: "JSON & Identifiers", types: [
                    "JSONB", "JSON", "UUID"
                ]),
                SQLTypeCategory(id: "binary", name: "Binary", types: [
                    "BYTEA"
                ])
            ]

        case .mySql:
            return [
                SQLTypeCategory(id: "text", name: "Text / String", types: [
                    "VARCHAR(255)", "TEXT", "MEDIUMTEXT", "LONGTEXT", "CHAR(50)", "VARCHAR(100)", "VARCHAR(500)"
                ]),
                SQLTypeCategory(id: "integer", name: "Integer", types: [
                    "INT", "BIGINT", "SMALLINT", "TINYINT"
                ]),
                SQLTypeCategory(id: "decimal", name: "Decimal / Numeric", types: [
                    "DECIMAL(10, 2)", "DOUBLE", "FLOAT"
                ]),
                SQLTypeCategory(id: "boolean", name: "Boolean", types: [
                    "BOOLEAN", "TINYINT(1)"
                ]),
                SQLTypeCategory(id: "datetime", name: "Date & Time", types: [
                    "DATETIME", "TIMESTAMP", "DATE", "TIME"
                ]),
                SQLTypeCategory(id: "json_blob", name: "JSON & Binary", types: [
                    "JSON", "BLOB", "LONGBLOB"
                ])
            ]

        case .sqlite:
            return [
                SQLTypeCategory(id: "affinity", name: "SQLite Affinities", types: [
                    "TEXT", "INTEGER", "REAL", "NUMERIC", "BLOB"
                ]),
                SQLTypeCategory(id: "compat", name: "SQL Compatibility Types", types: [
                    "VARCHAR(255)", "BIGINT", "DECIMAL(10, 2)", "BOOLEAN", "DATETIME", "JSON"
                ])
            ]

        default:
            return [
                SQLTypeCategory(id: "general", name: "General Types", types: [
                    "VARCHAR(255)", "TEXT", "INTEGER", "BIGINT", "DECIMAL(10, 2)", "BOOLEAN", "TIMESTAMP"
                ])
            ]
        }
    }

    /// Flattened list of all predefined types for an engine.
    public static func allTypes(for engine: DatabaseKind) -> [String] {
        categories(for: engine).flatMap(\.types)
    }
}

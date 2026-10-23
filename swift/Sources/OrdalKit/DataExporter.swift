import Foundation

/// Clean, robust data exporter supporting RFC 4180 CSV and JSON serialization
/// for query results, tables, and collections.
public enum DataExporter {
    /// Serializes columns and rows to RFC 4180 compliant CSV string.
    public static func csv(columns: [ColumnInfo], rows: [Row]) -> String {
        var lines: [String] = []
        // Header line
        let header = columns.map { escapeCSV($0.name) }.joined(separator: ",")
        lines.append(header)

        // Data rows
        for row in rows {
            let cells = columns.indices.map { i -> String in
                guard i < row.cells.count else { return "" }
                return escapeCSV(formatCSVValue(row.cells[i]))
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    /// Serializes rows to a JSON array string.
    public static func json(columns: [ColumnInfo], rows: [Row], pretty: Bool = true) -> String {
        var jsonObjects: [Any] = []
        for row in rows {
            // Check if this row represents a MongoDB/JSON document
            if columns.count == 1, columns[0].kind == .json, let firstCell = row.cells.first, case .json(let raw) = firstCell {
                if let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    jsonObjects.append(obj)
                    continue
                }
            }

            var dict: [String: Any] = [:]
            for (i, col) in columns.enumerated() where i < row.cells.count {
                dict[col.name] = valueToJSONObject(row.cells[i])
            }
            jsonObjects.append(dict)
        }

        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: jsonObjects, options: options),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    private static func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    private static func formatCSVValue(_ val: Value) -> String {
        switch val {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .float(let f): return String(f)
        case .decimal(let d), .date(let d), .time(let d), .uuid(let d): return d
        case .timestamp(let ts, _): return ts
        case .text(let t): return t
        case .json(let j): return j
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    private static func valueToJSONObject(_ val: Value) -> Any {
        switch val {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .float(let f): return f
        case .decimal(let d):
            if let num = Double(d) { return num }
            return d
        case .date(let d), .time(let d), .uuid(let d): return d
        case .timestamp(let ts, _): return ts
        case .text(let t): return t
        case .json(let j):
            if let data = j.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return obj
            }
            return j
        case .bytes(let data): return data.base64EncodedString()
        }
    }

    // MARK: - SQL & DDL Export

    /// Properly quotes an SQL identifier according to the database engine.
    public static func quoteIdentifier(_ name: String, engine: DatabaseKind) -> String {
        if engine == .mySql {
            return "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        } else {
            return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    /// Formats a single `Value` as an SQL literal safe for INSERT queries.
    public static func sqlLiteral(_ val: Value, engine: DatabaseKind) -> String {
        switch val {
        case .null:
            return "NULL"
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .int(let i):
            return String(i)
        case .float(let f):
            return String(f)
        case .decimal(let d):
            return d
        case .date(let d), .time(let d), .uuid(let d):
            return "'\(escapeSQL(d))'"
        case .timestamp(let ts, _):
            return "'\(escapeSQL(ts))'"
        case .text(let t):
            return "'\(escapeSQL(t))'"
        case .json(let j):
            return "'\(escapeSQL(j))'"
        case .bytes(let data):
            if engine == .postgres {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                return "'\\x\(hex)'::bytea"
            } else {
                let hex = data.map { String(format: "%02X", $0) }.joined()
                return "X'\(hex)'"
            }
        }
    }

    private static func escapeSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    /// Serializes rows into batched SQL INSERT INTO statements.
    public static func sqlInserts(
        table: String,
        columns: [ColumnInfo],
        rows: [Row],
        engine: DatabaseKind,
        batchSize: Int = 200
    ) -> String {
        guard !columns.isEmpty, !rows.isEmpty else {
            return "-- No data rows to export for \(table)"
        }

        let quotedTable = quoteIdentifier(table, engine: engine)
        let quotedCols = columns.map { quoteIdentifier($0.name, engine: engine) }.joined(separator: ", ")

        var statements: [String] = []

        for batchStart in stride(from: 0, to: rows.count, by: max(1, batchSize)) {
            let batchEnd = min(batchStart + batchSize, rows.count)
            let batchRows = rows[batchStart..<batchEnd]

            var valueClauses: [String] = []
            for row in batchRows {
                let cellValues = columns.indices.map { i -> String in
                    guard i < row.cells.count else { return "NULL" }
                    return sqlLiteral(row.cells[i], engine: engine)
                }
                valueClauses.append("  (\(cellValues.joined(separator: ", ")))")
            }

            let stmt = "INSERT INTO \(quotedTable) (\(quotedCols)) VALUES\n\(valueClauses.joined(separator: ",\n"));"
            statements.append(stmt)
        }

        return statements.joined(separator: "\n\n")
    }

    /// Reconstructs a clean CREATE TABLE DDL from TableMeta.
    public static func createTableDDL(
        table: String,
        meta: TableMeta,
        engine: DatabaseKind
    ) -> String {
        let quote = { (s: String) in quoteIdentifier(s, engine: engine) }
        var pk: [String] = []
        var colDefs: [String] = []

        for col in meta.columns {
            var def = "  \(quote(col.name)) \(col.typeName)"
            if !col.nullable {
                def += " NOT NULL"
            }
            if col.isKey || meta.keyColumns.contains(col.name) {
                let qk = quote(col.name)
                if !pk.contains(qk) { pk.append(qk) }
            }
            colDefs.append(def)
        }

        // Also add any keyColumns specified in meta
        for k in meta.keyColumns {
            let qk = quote(k)
            if !pk.contains(qk) { pk.append(qk) }
        }

        var body = colDefs
        if !pk.isEmpty {
            body.append("  PRIMARY KEY (\(pk.joined(separator: ", ")))")
        }

        return "CREATE TABLE \(quote(table)) (\n\(body.joined(separator: ",\n"))\n);"
    }

    // MARK: - MongoDB Script Export

    /// Serializes MongoDB collection structure and/or document data into JavaScript commands.
    public static func mongoCollectionScript(
        collection: String,
        indexes: [BrowseNode],
        rows: [Row],
        includeStructure: Bool,
        includeData: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("// -------------------------------------------------------------")
        lines.append("// Collection: \(collection)")
        lines.append("// -------------------------------------------------------------")

        if includeStructure {
            lines.append("db.createCollection(\"\(collection)\");")
            for idx in indexes where idx.name != "_id_" {
                if let detail = idx.detail, !detail.isEmpty {
                    lines.append("// Index: \(idx.name) (\(detail))")
                }
            }
        }

        if includeData && !rows.isEmpty {
            let docs = rows.compactMap { row -> String? in
                if let first = row.cells.first, case .json(let str) = first {
                    return str
                }
                return nil
            }
            if !docs.isEmpty {
                lines.append("db.\(collection).insertMany([")
                for (i, doc) in docs.enumerated() {
                    let comma = i < docs.count - 1 ? "," : ""
                    lines.append("  \(doc)\(comma)")
                }
                lines.append("]);")
            }
        }

        return lines.joined(separator: "\n")
    }
}

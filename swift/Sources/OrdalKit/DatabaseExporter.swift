import Foundation

/// Defines a database object to export (single table/collection, or whole database/schema).
public struct ExportTarget: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case table
        case view
        case collection
        case database
        case schema
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

    public var isContainer: Bool {
        kind == .database || kind == .schema
    }

    public var displayTitle: String {
        switch kind {
        case .table: "Table: \(name)"
        case .view: "View: \(name)"
        case .collection: "Collection: \(name)"
        case .database: "Database: \(name)"
        case .schema: "Schema: \(name)"
        }
    }
}

/// What to include in the exported result.
public enum ExportContent: String, CaseIterable, Identifiable, Sendable {
    case structureOnly = "Structure Only"
    case dataOnly = "Data Only"
    case both = "Structure & Data"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .structureOnly: "Schema definition / CREATE TABLE SQL without rows"
        case .dataOnly: "Records only (INSERT statements, JSON array, or CSV)"
        case .both: "Complete backup with schema creation followed by data"
        }
    }
}

/// Output file formats supported by Ordal export.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case sql = "SQL (.sql)"
    case mongoScript = "Mongo Script (.js)"
    case json = "JSON (.json)"
    case csv = "CSV (.csv)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .sql: "sql"
        case .mongoScript: "js"
        case .json: "json"
        case .csv: "csv"
        }
    }
}

/// Row limit choices for data export.
public enum ExportLimit: String, CaseIterable, Identifiable, Sendable {
    case hundred = "100 rows"
    case thousand = "1,000 rows"
    case tenThousand = "10,000 rows"
    case all = "All rows (up to 50,000)"

    public var id: String { rawValue }

    public var rowCount: Int {
        switch self {
        case .hundred: 100
        case .thousand: 1000
        case .tenThousand: 10000
        case .all: 50000
        }
    }
}

/// Comprehensive options configured in the export dialog.
public struct ExportOptions: Sendable {
    public var content: ExportContent
    public var format: ExportFormat
    public var limit: ExportLimit

    public init(content: ExportContent = .both, format: ExportFormat = .sql, limit: ExportLimit = .all) {
        self.content = content
        self.format = format
        self.limit = limit
    }
}

/// High-level orchestration service for single-table, collection, and whole-database backups.
public enum ExportService {
    /// Formats that make sense for a given engine and export target.
    public static func availableFormats(engine: DatabaseKind, isContainer: Bool) -> [ExportFormat] {
        if engine == .mongoDb {
            return isContainer ? [.json, .mongoScript] : [.json, .mongoScript, .csv]
        } else {
            return isContainer ? [.sql, .json] : [.sql, .json, .csv]
        }
    }

    /// Recursively discovers all exportable tables, views, and collections under a database/schema path.
    public static func findExportableRelations(
        session: Session,
        rootPath: [String]
    ) async throws -> [(name: String, path: [String], kind: NodeKind)] {
        var results: [(name: String, path: [String], kind: NodeKind)] = []

        func walk(currentPath: [String]) async throws {
            let children = try await session.listChildren(path: currentPath)
            for child in children {
                let childPath = currentPath + [child.name]
                switch child.kind {
                case .table, .view, .collection:
                    results.append((name: child.name, path: childPath, kind: child.kind))
                case .schema, .folder:
                    try await walk(currentPath: childPath)
                default:
                    break
                }
            }
        }

        try await walk(currentPath: rootPath)
        return results
    }

    /// Performs the export asynchronously according to target and options.
    public static func export(
        session: Session,
        engine: DatabaseKind,
        target: ExportTarget,
        options: ExportOptions,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        let isContainer = target.isContainer
        let includeStructure = options.content != .dataOnly
        let includeData = options.content != .structureOnly

        if isContainer {
            return try await exportContainer(
                session: session,
                engine: engine,
                target: target,
                includeStructure: includeStructure,
                includeData: includeData,
                options: options,
                onProgress: onProgress
            )
        } else {
            return try await exportSingleRelation(
                session: session,
                engine: engine,
                name: target.name,
                path: target.path,
                kind: target.kind,
                includeStructure: includeStructure,
                includeData: includeData,
                options: options,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Single Table / Collection Export

    private static func exportSingleRelation(
        session: Session,
        engine: DatabaseKind,
        name: String,
        path: [String],
        kind: ExportTarget.Kind,
        includeStructure: Bool,
        includeData: Bool,
        options: ExportOptions,
        onProgress: ((String) -> Void)?
    ) async throws -> String {
        onProgress?("Exporting \(name)...")

        // 1. Fetch metadata if structure needed
        var meta: TableMeta?
        var indexes: [BrowseNode] = []
        if includeStructure {
            meta = try? await session.tableMeta(path: path)
            if engine == .mongoDb {
                let children = (try? await session.listChildren(path: path)) ?? []
                indexes = children.filter { $0.kind == .index }
            }
        }

        // 2. Fetch data rows if data needed
        var page: TablePage?
        if includeData {
            page = try? await session.fetchPage(
                path: path,
                cursor: .first,
                size: UInt32(options.limit.rowCount),
                sort: nil
            )
        }

        // 3. Render according to format
        switch options.format {
        case .csv:
            guard let page else { return "" }
            return DataExporter.csv(columns: page.columns, rows: page.rows)

        case .json:
            if !includeStructure, let page {
                return DataExporter.json(columns: page.columns, rows: page.rows, pretty: true)
            }
            var root: [String: Any] = [
                "name": name,
                "kind": kind.rawValue,
                "engine": engine.label
            ]
            if let meta {
                root["columns"] = meta.columns.map { [
                    "name": $0.name,
                    "type": $0.typeName,
                    "nullable": $0.nullable,
                    "isKey": $0.isKey
                ] }
                root["primaryKey"] = meta.keyColumns
            }
            if engine == .mongoDb && !indexes.isEmpty {
                root["indexes"] = indexes.map { ["name": $0.name, "detail": $0.detail ?? ""] }
            }
            if let page {
                let jsonRows = DataExporter.json(columns: page.columns, rows: page.rows, pretty: false)
                if let data = jsonRows.data(using: String.Encoding.utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) {
                    root["data"] = arr
                }
            }
            if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: outData, encoding: .utf8) {
                return str
            }
            return "{}"

        case .mongoScript:
            return DataExporter.mongoCollectionScript(
                collection: name,
                indexes: indexes,
                rows: page?.rows ?? [],
                includeStructure: includeStructure,
                includeData: includeData
            )

        case .sql:
            var sections: [String] = []
            let isoDate = ISO8601DateFormatter().string(from: Date())
            sections.append("""
            -- -------------------------------------------------------------
            -- Table Export: \(name)
            -- Engine: \(engine.label)
            -- Exported At: \(isoDate)
            -- -------------------------------------------------------------
            """)

            if includeStructure {
                if let meta {
                    sections.append(DataExporter.createTableDDL(table: name, meta: meta, engine: engine))
                } else if kind == .view {
                    sections.append("-- View: \(name)")
                }
            }

            if includeData, let page {
                sections.append(DataExporter.sqlInserts(
                    table: name,
                    columns: page.columns,
                    rows: page.rows,
                    engine: engine
                ))
            }

            return sections.joined(separator: "\n\n")
        }
    }

    // MARK: - Whole Database / Schema Container Export

    private static func exportContainer(
        session: Session,
        engine: DatabaseKind,
        target: ExportTarget,
        includeStructure: Bool,
        includeData: Bool,
        options: ExportOptions,
        onProgress: ((String) -> Void)?
    ) async throws -> String {
        onProgress?("Discovering objects in \(target.name)...")
        let relations = try await findExportableRelations(session: session, rootPath: target.path)

        if relations.isEmpty {
            return engine.isSQL
                ? "-- No tables or views found in \(target.name)."
                : "// No collections found in \(target.name)."
        }

        let isoDate = ISO8601DateFormatter().string(from: Date())

        if options.format == .json {
            var dbDict: [String: Any] = [
                "database": target.name,
                "engine": engine.label,
                "exportedAt": isoDate,
                "mode": options.content.rawValue
            ]
            var objectsDict: [String: Any] = [:]

            for (i, rel) in relations.enumerated() {
                onProgress?("Exporting \(rel.name) (\(i + 1)/\(relations.count))...")
                var objDict: [String: Any] = ["kind": "\(rel.kind)"]

                if includeStructure, let meta = try? await session.tableMeta(path: rel.path) {
                    objDict["columns"] = meta.columns.map { [
                        "name": $0.name,
                        "type": $0.typeName,
                        "nullable": $0.nullable,
                        "isKey": $0.isKey
                    ] }
                    objDict["primaryKey"] = meta.keyColumns
                }

                if includeData, let page = try? await session.fetchPage(
                    path: rel.path,
                    cursor: .first,
                    size: UInt32(options.limit.rowCount),
                    sort: nil
                ) {
                    let jsonRows = DataExporter.json(columns: page.columns, rows: page.rows, pretty: false)
                    if let data = jsonRows.data(using: String.Encoding.utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) {
                        objDict["data"] = arr
                    }
                }

                objectsDict[rel.name] = objDict
            }

            dbDict["objects"] = objectsDict
            if let outData = try? JSONSerialization.data(withJSONObject: dbDict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: outData, encoding: .utf8) {
                return str
            }
            return "{}"
        }

        if engine == .mongoDb {
            var scriptLines: [String] = []
            scriptLines.append("""
            // =============================================================
            // MongoDB Database Export: \(target.name)
            // Total Collections: \(relations.count)
            // Mode: \(options.content.rawValue)
            // Date: \(isoDate)
            // =============================================================
            """)

            for (i, rel) in relations.enumerated() {
                onProgress?("Exporting collection \(rel.name) (\(i + 1)/\(relations.count))...")
                var indexes: [BrowseNode] = []
                if includeStructure {
                    let children = (try? await session.listChildren(path: rel.path)) ?? []
                    indexes = children.filter { $0.kind == .index }
                }

                var page: TablePage?
                if includeData {
                    page = try? await session.fetchPage(
                        path: rel.path,
                        cursor: .first,
                        size: UInt32(options.limit.rowCount),
                        sort: nil
                    )
                }

                let script = DataExporter.mongoCollectionScript(
                    collection: rel.name,
                    indexes: indexes,
                    rows: page?.rows ?? [],
                    includeStructure: includeStructure,
                    includeData: includeData
                )
                scriptLines.append(script)
            }

            return scriptLines.joined(separator: "\n\n")
        }

        // SQL Export
        var sqlSections: [String] = []
        sqlSections.append("""
        -- =============================================================
        -- Database / Schema Backup: \(target.name)
        -- Engine: \(engine.label)
        -- Total Objects: \(relations.count)
        -- Mode: \(options.content.rawValue)
        -- Exported At: \(isoDate)
        -- =============================================================
        """)

        for (i, rel) in relations.enumerated() {
            onProgress?("Exporting \(rel.name) (\(i + 1)/\(relations.count))...")
            var tableSection: [String] = []
            tableSection.append("""
            -- -------------------------------------------------------------
            -- Object: \(rel.name) (\(rel.kind))
            -- -------------------------------------------------------------
            """)

            if includeStructure {
                if let meta = try? await session.tableMeta(path: rel.path) {
                    tableSection.append(DataExporter.createTableDDL(table: rel.name, meta: meta, engine: engine))
                } else {
                    tableSection.append("-- \(rel.kind): \(rel.name)")
                }
            }

            if includeData, let page = try? await session.fetchPage(
                path: rel.path,
                cursor: .first,
                size: UInt32(options.limit.rowCount),
                sort: nil
            ) {
                tableSection.append(DataExporter.sqlInserts(
                    table: rel.name,
                    columns: page.columns,
                    rows: page.rows,
                    engine: engine
                ))
            }

            sqlSections.append(tableSection.joined(separator: "\n\n"))
        }

        return sqlSections.joined(separator: "\n\n")
    }
}

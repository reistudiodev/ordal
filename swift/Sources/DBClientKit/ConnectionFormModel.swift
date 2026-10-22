import Foundation
import Observation

/// The connection sheet. Each engine gets the fields it actually uses
/// (a file for SQLite, a topology for MongoDB, a db index for Redis);
/// pasting a URL is an optional shortcut that fills them in.
@MainActor @Observable
public final class ConnectionFormModel {
    public enum TestState: Equatable {
        case idle
        case testing
        case succeeded(String)
        case failed(String)
    }

    /// How a MongoDB deployment is reached.
    public enum MongoTopology: String, CaseIterable, Identifiable {
        case standalone = "Single server"
        case replicaSet = "Replica set"
        case srv = "SRV (Atlas)"
        public var id: String { rawValue }
    }

    /// Fields that can show an inline error.
    public enum Field: Hashable {
        case host, port, file, hosts, database
    }

    public var url = "" {
        didSet { if url != oldValue { applyURL() } }
    }
    public var name = ""
    public var kind: DatabaseKind = .postgres {
        didSet {
            guard kind != oldValue else { return }
            if port.isEmpty || port == String(oldValue.defaultPort) { port = String(kind.defaultPort) }
            if kind == .redis, database.isEmpty { database = "0" }
            if oldValue == .redis, database == "0" { database = "" }
            if kind == .sqlite || oldValue == .sqlite { host = kind == .sqlite ? "" : "localhost" }
            test = .idle
        }
    }
    public var host = "localhost"
    public var port = "5432"
    public var database = ""
    public var username = ""
    public var password = ""
    public var environment: EnvironmentTag = .local
    public var readOnly = false
    public var tls: TlsMode = .prefer

    // MongoDB
    public var mongoTopology: MongoTopology = .standalone
    /// Replica set seed list, one `host:port` per line (commas also accepted).
    public var mongoHosts = ""
    public var authSource = ""
    public var replicaSetName = ""
    public var directConnection = false

    public private(set) var urlError: String?
    public private(set) var test: TestState = .idle
    public private(set) var saveError: String?

    /// Set when editing a saved connection.
    public private(set) var existing: ConnectionConfig?
    /// Engine options this form has no field for; kept as they were.
    private var extraOptions: [String: String] = [:]
    private var passwordEdited = false

    public init(kind: DatabaseKind = .postgres) {
        self.kind = kind
        port = String(kind.defaultPort)
        if kind == .redis { database = "0" }
        if kind == .sqlite { host = "" }
    }

    public init(editing config: ConnectionConfig) {
        existing = config
        load(config)
        environment = config.environment
        readOnly = config.readOnly
    }

    public var isEditing: Bool { existing != nil }

    public func passwordChanged() { passwordEdited = true }

    // MARK: Engine-specific labels and defaults

    /// The name used when the Name field is left empty.
    public var suggestedName: String {
        switch kind {
        case .sqlite:
            return host.isEmpty ? "" : URL(fileURLWithPath: host).lastPathComponent
        case .mongoDb where mongoTopology == .replicaSet:
            let first = Self.hostList(mongoHosts).first ?? "replica set"
            return database.isEmpty ? first : "\(database) @ \(first)"
        case .redis:
            return host.isEmpty ? "" : "\(host) db\(database.isEmpty ? "0" : database)"
        default:
            return database.isEmpty ? host : "\(database) @ \(host)"
        }
    }

    /// What an empty Database field means for this engine.
    public var databasePlaceholder: String {
        switch kind {
        case .postgres: "postgres"
        case .mySql: "None (browse all)"
        case .mongoDb: "test"
        case .redis: "0"
        case .sqlite: ""
        }
    }

    public var usesPassword: Bool { kind != .sqlite }

    // MARK: Validation

    /// Inline problems, by field. Empty when the form can be saved.
    public var problems: [Field: String] {
        var p: [Field: String] = [:]
        func needsPort() {
            let t = port.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { p[.port] = "Required" } else if UInt16(t) == nil || t == "0" { p[.port] = "A number from 1 to 65535" }
        }
        switch kind {
        case .sqlite:
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                p[.file] = "Choose a database file"
            } else if host != ":memory:", !FileManager.default.fileExists(atPath: (host as NSString).expandingTildeInPath) {
                p[.file] = "File not found. Use Create New… to make one"
            }
        case .mongoDb where mongoTopology == .replicaSet:
            let hosts = Self.hostList(mongoHosts)
            if hosts.isEmpty {
                p[.hosts] = "Add at least one host:port"
            } else if let bad = hosts.first(where: { Self.splitHostPort($0) == nil }) {
                p[.hosts] = "`\(bad)` is not host:port"
            }
        case .mongoDb where mongoTopology == .srv:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { p[.host] = "Required, e.g. cluster0.abcde.mongodb.net" }
            if host.contains(":") { p[.host] = "SRV names have no port" }
        case .redis:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { p[.host] = "Required" }
            needsPort()
            let db = database.trimmingCharacters(in: .whitespaces)
            if !db.isEmpty, Int(db).map({ $0 < 0 }) ?? true { p[.database] = "A database index such as 0" }
        default:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { p[.host] = "Required" }
            needsPort()
        }
        return p
    }

    public var canSave: Bool { problems.isEmpty }

    // MARK: URL import

    /// Fills the fields from a pasted URL. The password goes to the password
    /// field (and later the keychain), never into the saved config.
    func applyURL() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { urlError = nil; return }
        do {
            let parsed = try parseConnectionUrl(url: trimmed)
            load(parsed.config)
            if let p = parsed.password {
                password = p
                passwordEdited = true
            }
            urlError = nil
        } catch {
            urlError = describe(error)
        }
    }

    /// Spreads a config over the engine-specific fields.
    private func load(_ c: ConnectionConfig) {
        kind = c.kind
        name = c.name
        host = c.host
        port = c.kind == .sqlite ? "" : String(c.port)
        database = c.database
        username = c.username
        tls = c.tls
        var options = c.options
        if c.kind == .mongoDb {
            authSource = options.removeValue(forKey: "authSource") ?? ""
            replicaSetName = options.removeValue(forKey: "replicaSet") ?? ""
            directConnection = options.removeValue(forKey: "directConnection") == "true"
            if options.removeValue(forKey: "srv") == "true" {
                mongoTopology = .srv
            } else if c.host.contains(",") || !replicaSetName.isEmpty {
                mongoTopology = .replicaSet
                mongoHosts = Self.hostList(c.host)
                    .map { $0.contains(":") ? $0 : "\($0):\(c.port)" }
                    .joined(separator: "\n")
                host = ""
            } else {
                mongoTopology = .standalone
            }
        }
        if c.kind == .sqlite { database = "" }
        extraOptions = options
    }

    // MARK: Building the config

    public func makeConfig() throws -> ConnectionConfig {
        if let (_, message) = problems.first {
            throw CoreError.InvalidConfig(message: message)
        }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var options = extraOptions
        var cfgHost = trim(host)
        var cfgPort = UInt16(trim(port)) ?? kind.defaultPort
        var cfgDatabase = trim(database)
        var cfgUser = trim(username)
        var cfgTls = tls

        switch kind {
        case .sqlite:
            cfgHost = (cfgHost as NSString).expandingTildeInPath
            cfgPort = 0
            cfgDatabase = "main"
            cfgUser = ""
            cfgTls = .prefer
        case .mongoDb:
            switch mongoTopology {
            case .standalone:
                if directConnection { options["directConnection"] = "true" }
            case .replicaSet:
                cfgHost = Self.hostList(mongoHosts).joined(separator: ",")
                cfgPort = kind.defaultPort
                if !trim(replicaSetName).isEmpty { options["replicaSet"] = trim(replicaSetName) }
            case .srv:
                cfgPort = kind.defaultPort
                options["srv"] = "true"
            }
            if !trim(authSource).isEmpty { options["authSource"] = trim(authSource) }
        case .redis:
            if cfgDatabase.isEmpty { cfgDatabase = "0" }
        case .postgres, .mySql:
            break
        }

        let trimmedName = trim(name)
        return ConnectionConfig(
            id: existing?.id ?? "",
            name: trimmedName.isEmpty ? suggestedName : trimmedName,
            kind: kind,
            host: cfgHost,
            port: cfgPort,
            database: cfgDatabase,
            username: cfgUser,
            environment: environment,
            colorTag: existing?.colorTag,
            readOnly: readOnly,
            tls: cfgTls,
            options: options
        )
    }

    /// `nil` keeps the stored password; editing it (even to empty) replaces it.
    var passwordToSave: String? {
        guard usesPassword else { return isEditing ? "" : nil }
        if !isEditing { return password.isEmpty ? nil : password }
        return passwordEdited ? password : nil
    }

    // MARK: Actions

    public func runTest(using manager: ConnectionManager) async {
        test = .testing
        do {
            let config = try makeConfig()
            let info = try await manager.test(config: config, password: passwordToSave)
            test = .succeeded("\(info.engine) \(info.version)")
        } catch {
            test = .failed(describe(error))
        }
    }

    /// Saves and returns the stored config, or nil with `saveError` set.
    public func save(using manager: ConnectionManager) -> ConnectionConfig? {
        do {
            let saved = try manager.save(config: try makeConfig(), password: passwordToSave)
            saveError = nil
            return saved
        } catch {
            saveError = describe(error)
            return nil
        }
    }

    /// Creates an empty SQLite database file at `path` and selects it.
    public func createSQLiteFile(at path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CoreError.InvalidConfig(message: "could not create \(path)")
        }
        host = path
    }

    // MARK: Helpers

    static func hostList(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func splitHostPort(_ s: String) -> (String, UInt16)? {
        guard let i = s.lastIndex(of: ":"), let port = UInt16(s[s.index(after: i)...]), port > 0 else { return nil }
        let host = String(s[..<i])
        return host.isEmpty ? nil : (host, port)
    }
}

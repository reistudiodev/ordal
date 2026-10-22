/// What the UI must do before running a statement.
public enum SafetyDecision: Equatable, Sendable {
    case run
    /// Ask first. `strong` means production: the user types the database name.
    case confirm(strong: Bool, reason: String)
    case blocked(String)
}

public enum Safety {
    public static func decide(kind: StatementKind, environment: EnvironmentTag, readOnly: Bool) -> SafetyDecision {
        let prod = environment == .prod
        if readOnly && kind != .read {
            return .blocked("This connection is read-only.")
        }
        switch kind {
        case .read:
            return .run
        case .destructive:
            return .confirm(strong: prod, reason: "This statement can delete or overwrite data and cannot be undone.")
        case .write, .ddl:
            return prod ? .confirm(strong: false, reason: "This changes data on a production connection.") : .run
        }
    }
}

extension EnvironmentTag {
    public var label: String {
        switch self {
        case .local: "Local"
        case .dev: "Development"
        case .staging: "Staging"
        case .prod: "Production"
        }
    }

    public static let all: [EnvironmentTag] = [.local, .dev, .staging, .prod]
}

extension DatabaseKind {
    public var label: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mySql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        case .mongoDb: "MongoDB"
        case .redis: "Redis"
        }
    }

    public var defaultPort: UInt16 {
        switch self {
        case .postgres: 5432
        case .mySql: 3306
        case .sqlite: 0
        case .mongoDb: 27017
        case .redis: 6379
        }
    }

    /// Engines whose query language is SQL (highlighting, formatting, DDL).
    public var isSQL: Bool {
        switch self {
        case .postgres, .mySql, .sqlite: true
        case .mongoDb, .redis: false
        }
    }

    public static let all: [DatabaseKind] = [.postgres, .mySql, .sqlite, .mongoDb, .redis]
}

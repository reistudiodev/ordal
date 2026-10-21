import Foundation
import Observation

/// The "New connection" sheet: paste a URL or fill the fields, then test and save.
@MainActor @Observable
public final class ConnectionFormModel {
    public enum TestState: Equatable {
        case idle
        case testing
        case succeeded(String)
        case failed(String)
    }

    public var url = "" {
        didSet { if url != oldValue { applyURL() } }
    }
    public var name = ""
    public var kind: DatabaseKind = .postgres {
        didSet { if kind != oldValue, port == String(oldValue.defaultPort) || port.isEmpty { port = String(kind.defaultPort) } }
    }
    public var host = "localhost"
    public var port = "5432"
    public var database = ""
    public var username = ""
    public var password = ""
    public var environment: EnvironmentTag = .local
    public var readOnly = false
    public var tls: TlsMode = .prefer
    public private(set) var urlError: String?
    public private(set) var test: TestState = .idle
    public private(set) var saveError: String?

    /// Set when editing a saved connection.
    public private(set) var existing: ConnectionConfig?
    private var options: [String: String] = [:]
    private var passwordEdited = false

    public init() {}

    public init(editing config: ConnectionConfig) {
        existing = config
        name = config.name
        kind = config.kind
        host = config.host
        port = String(config.port)
        database = config.database
        username = config.username
        environment = config.environment
        readOnly = config.readOnly
        tls = config.tls
        options = config.options
    }

    public var isEditing: Bool { existing != nil }

    public func passwordChanged() { passwordEdited = true }

    /// Fills the fields from a pasted URL. The password goes to the password
    /// field (and later the keychain), never into the saved config.
    func applyURL() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { urlError = nil; return }
        do {
            let parsed = try parseConnectionUrl(url: trimmed)
            let c = parsed.config
            kind = c.kind
            name = c.name
            host = c.host
            port = String(c.port)
            database = c.database
            username = c.username
            tls = c.tls
            options = c.options
            if let p = parsed.password {
                password = p
                passwordEdited = true
            }
            urlError = nil
        } catch {
            urlError = describe(error)
        }
    }

    public func makeConfig() throws -> ConnectionConfig {
        let portNumber: UInt16
        if kind == .sqlite {
            portNumber = 0
        } else if let p = UInt16(port.trimmingCharacters(in: .whitespaces)) {
            portNumber = p
        } else {
            throw CoreError.InvalidConfig(message: "port must be a number between 0 and 65535")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return ConnectionConfig(
            id: existing?.id ?? "",
            name: trimmedName.isEmpty ? host : trimmedName,
            kind: kind,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            database: database.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            environment: environment,
            colorTag: existing?.colorTag,
            readOnly: readOnly,
            tls: tls,
            options: options
        )
    }

    /// `nil` keeps the stored password; editing it (even to empty) replaces it.
    var passwordToSave: String? {
        if !isEditing { return password.isEmpty ? nil : password }
        return passwordEdited ? password : nil
    }

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
}

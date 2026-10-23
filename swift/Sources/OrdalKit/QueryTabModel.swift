import Foundation
import Observation

/// A query editor tab and its latest result.
@MainActor @Observable
public final class QueryTabModel: Identifiable {
    public enum Status: Equatable {
        case idle
        case running
        case finished
        case failed(String)
        case cancelled
    }

    /// A statement waiting for the user's OK.
    public struct PendingConfirmation: Equatable {
        public let sql: String
        public let strong: Bool
        public let reason: String
        /// What the user must type for a strong confirmation.
        public let expectedText: String
    }

    public let id = UUID()
    public var title: String
    public var text: String
    /// The editor's selection (UTF-16 range); run uses it when non-empty.
    public var selection: NSRange = NSRange(location: 0, length: 0)
    public var database: String?
    public private(set) var status: Status = .idle
    public private(set) var pager: CursorPager?
    public private(set) var pending: PendingConfirmation?
    public private(set) var history: [HistoryEntry] = []
    /// Set when a statement was blocked (read-only).
    public private(set) var notice: String?

    /// The `.sql` file this tab was opened from or saved to.
    public private(set) var fileURL: URL?
    private var savedText: String

    var session: Session
    let manager: ConnectionManager
    /// Called when a query fails because the connection dropped.
    var onConnectionLost: ((String) -> Void)?
    private var startedAt = Date()

    init(title: String, text: String = "", session: Session, manager: ConnectionManager) {
        self.title = title
        self.text = text
        self.savedText = text
        self.session = session
        self.manager = manager
    }

    /// Unsaved changes since the last save or open (only for file-backed or edited tabs).
    public var isDirty: Bool { text != savedText }

    /// Writes the editor text to a `.sql` (or `.json` / `.redis`) file.
    public func save(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
        savedText = text
        title = url.deletingPathExtension().lastPathComponent
    }

    /// Saves to the file this tab already has; returns false when there is none.
    @discardableResult
    public func save() throws -> Bool {
        guard let fileURL else { return false }
        try save(to: fileURL)
        return true
    }

    func loaded(from url: URL) {
        fileURL = url
        savedText = text
    }

    var config: ConnectionConfig { session.config() }

    /// The selected text, or the whole editor when nothing is selected.
    public var statementToRun: String {
        let ns = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            return ns.substring(with: selection)
        }
        return text
    }

    public var isRunning: Bool { status == .running }

    /// Runs the selection (or everything), asking first when the safety rules say so.
    public func run() async {
        let sql = statementToRun.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty, !isRunning else { return }
        notice = nil
        let config = self.config
        switch Safety.decide(kind: session.classify(query: sql), environment: config.environment, readOnly: config.readOnly) {
        case .run:
            await execute(sql)
        case .confirm(let strong, let reason):
            pending = PendingConfirmation(sql: sql, strong: strong, reason: reason, expectedText: config.database.isEmpty ? config.name : config.database)
        case .blocked(let message):
            notice = message
        }
    }

    public func confirmPending() async {
        guard let p = pending else { return }
        pending = nil
        await execute(p.sql)
    }

    public func dismissPending() {
        pending = nil
    }

    public func cancel() {
        pager?.cancel()
    }

    private func execute(_ sql: String) async {
        status = .running
        startedAt = Date()
        do {
            let cursor = try session.query(query: sql, database: database)
            let pager = CursorPager(cursor: cursor)
            self.pager = pager
            await pager.start()
            if let error = pager.error {
                status = error == CoreError.Cancelled.message ? .cancelled : .failed(error)
                if pager.lostConnection { onConnectionLost?(error) }
            } else {
                status = .finished
            }
            record(sql, succeeded: pager.error == nil, rows: pager.rowsAffected ?? UInt64(pager.rowCount), ms: pager.elapsedMs)
        } catch {
            status = .failed(describe(error))
            if case .Connection? = error as? CoreError { onConnectionLost?(describe(error)) }
            record(sql, succeeded: false, rows: nil, ms: UInt64(Date().timeIntervalSince(startedAt) * 1000))
        }
    }

    private func record(_ sql: String, succeeded: Bool, rows: UInt64?, ms: UInt64) {
        let entry = HistoryEntry(
            query: sql,
            executedAtMs: Int64(startedAt.timeIntervalSince1970 * 1000),
            durationMs: ms,
            rows: rows,
            succeeded: succeeded
        )
        try? manager.addHistory(id: config.id, entry: entry)
        history.insert(entry, at: 0)
    }

    public func loadHistory() {
        history = (try? manager.history(id: config.id, limit: 200)) ?? []
    }

    /// Clears both in-memory history (saving memory) and the persisted history file.
    public func clearHistory() {
        history.removeAll()
        try? manager.clearHistory(id: config.id)
    }

    public func format() {
        guard config.kind.isSQL else { return }
        if selection.length > 0, NSMaxRange(selection) <= (text as NSString).length {
            let formatted = SQLFormatter.format(statementToRun)
            text = (text as NSString).replacingCharacters(in: selection, with: formatted)
            selection = NSRange(location: selection.location, length: (formatted as NSString).length)
        } else {
            text = SQLFormatter.format(text)
        }
    }
}

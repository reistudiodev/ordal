import Foundation
import Observation

/// What a virtualised grid reads from. The grid only asks for the rows it is
/// about to draw; the source loads them in pages in the background.
@MainActor
public protocol GridDataSource: AnyObject {
    var columns: [ColumnInfo] { get }
    var rowCount: Int { get }
    /// The row if it is loaded. Asking for a row that isn't schedules its page.
    func row(at index: Int) -> Row?
    /// Bumped whenever columns, rowCount or loaded rows change.
    var version: Int { get }
}

/// Query results from a forward-only cursor. Pages are fetched ahead of the
/// scroll position, and loading stops at `cap` rows so memory stays bounded.
@MainActor @Observable
public final class CursorPager: GridDataSource {
    public nonisolated static let pageSize: UInt32 = 500
    public nonisolated static let defaultCap = 100_000

    public private(set) var columns: [ColumnInfo] = []
    public private(set) var rows: [Row] = []
    public private(set) var isDone = false
    public private(set) var isLoading = false
    /// More rows exist than were kept.
    public private(set) var isTruncated = false
    public private(set) var error: String?
    public private(set) var version = 0

    public var rowCount: Int { rows.count }

    private let cursor: QueryCursor
    private let cap: Int
    private var wanted: Int

    public init(cursor: QueryCursor, cap: Int = CursorPager.defaultCap) {
        self.cursor = cursor
        self.cap = cap
        self.wanted = Int(Self.pageSize) * 2
    }

    public var elapsedMs: UInt64 { cursor.elapsedMs() }
    public var rowsAffected: UInt64? { cursor.rowsAffected() }

    /// Loads columns and the first pages. Returns when the first page is in
    /// (or the query ended), so callers can show "running" until then.
    public func start() async {
        do {
            columns = try await cursor.columns()
            version += 1
        } catch {
            fail(error)
            return
        }
        await fill()
    }

    public func row(at index: Int) -> Row? {
        if index >= rows.count - Int(Self.pageSize), !isDone, !isTruncated {
            wanted = max(wanted, index + Int(Self.pageSize) * 2)
            if !isLoading { Task { await fill() } }
        }
        return index < rows.count ? rows[index] : nil
    }

    public func cancel() {
        cursor.cancel()
    }

    private func fill() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        while !isDone, rows.count < min(wanted, cap) {
            do {
                let room = UInt32(min(Int(Self.pageSize), cap - rows.count))
                let page = try await cursor.nextPage(maxRows: room)
                rows.append(contentsOf: page.rows)
                isDone = page.done
                version += 1
            } catch {
                fail(error)
                return
            }
        }
        if !isDone, rows.count >= cap {
            isTruncated = true
            cursor.cancel()
            version += 1
        }
    }

    private func fail(_ e: Error) {
        error = describe(e)
        isDone = true
        version += 1
    }
}

/// A table or view with random access: rows come from `fetchWindow` by
/// offset, and only the most recently used pages are kept.
@MainActor @Observable
public final class WindowPager: GridDataSource {
    public nonisolated static let pageSize = 500
    public nonisolated static let keptPages = 20

    public private(set) var columns: [ColumnInfo] = []
    public private(set) var rowCount = 0
    /// False when `rowCount` is the engine's estimate.
    public private(set) var countIsExact = true
    public private(set) var error: String?
    public private(set) var version = 0

    private let session: Session
    private let path: [String]
    private var pages: [Int: [Row]] = [:]
    private var recent: [Int] = []
    private var inFlight: Set<Int> = []

    public init(session: Session, path: [String]) {
        self.session = session
        self.path = path
    }

    public var loadedPageCount: Int { pages.count }

    /// Counts the rows and loads the first page.
    public func start() async {
        do {
            let count = try await session.rowCount(path: path)
            rowCount = Int(count.count)
            countIsExact = count.exact
        } catch {
            self.error = describe(error)
        }
        await load(page: 0)
    }

    public func row(at index: Int) -> Row? {
        let page = index / Self.pageSize
        guard let rows = pages[page] else {
            schedule(page)
            return nil
        }
        touch(page)
        let offset = index % Self.pageSize
        // Prefetch the next page when the reader nears the end of this one.
        if offset > Self.pageSize * 3 / 4 { schedule(page + 1) }
        return offset < rows.count ? rows[offset] : nil
    }

    /// Drops loaded pages and counts again (after edits, or on demand).
    public func reload() async {
        pages = [:]
        recent = []
        version += 1
        await start()
    }

    private func schedule(_ page: Int) {
        guard page >= 0, page * Self.pageSize < max(rowCount, 1), pages[page] == nil, !inFlight.contains(page) else { return }
        Task { await load(page: page) }
    }

    private func load(page: Int) async {
        guard !inFlight.contains(page) else { return }
        inFlight.insert(page)
        defer { inFlight.remove(page) }
        do {
            let window = try await session.fetchWindow(
                path: path, offset: UInt64(page * Self.pageSize), limit: UInt32(Self.pageSize))
            if columns.isEmpty || columns != window.columns, !window.columns.isEmpty { columns = window.columns }
            pages[page] = window.rows
            touch(page)
            evict()
            reconcileCount(page: page, got: window.rows.count)
            version += 1
        } catch {
            self.error = describe(error)
            version += 1
        }
    }

    /// Estimates can be off; trust what the pages actually returned.
    private func reconcileCount(page: Int, got: Int) {
        let start = page * Self.pageSize
        if got < Self.pageSize {
            rowCount = start + got
            countIsExact = true
        } else if start + got > rowCount {
            rowCount = start + got + Self.pageSize
        }
    }

    private func touch(_ page: Int) {
        if let i = recent.firstIndex(of: page) { recent.remove(at: i) }
        recent.append(page)
    }

    private func evict() {
        while recent.count > Self.keptPages {
            pages[recent.removeFirst()] = nil
        }
    }
}

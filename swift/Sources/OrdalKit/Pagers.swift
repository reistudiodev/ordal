import Foundation
import Observation

/// A column's sort state in a grid header.
public struct GridSort: Equatable, Sendable {
    public let column: String
    public let descending: Bool

    public init(column: String, descending: Bool) {
        self.column = column
        self.descending = descending
    }
}

/// What a virtualised grid reads from. The grid only asks for the rows it is
/// about to draw.
@MainActor
public protocol GridDataSource: AnyObject {
    var columns: [ColumnInfo] { get }
    var rowCount: Int { get }
    /// The row if it is loaded. Asking for a row that isn't may schedule a load.
    func row(at index: Int) -> Row?
    /// Bumped whenever columns, rowCount or loaded rows change.
    var version: Int { get }
    /// The current sort, shown as a header arrow.
    var sort: GridSort? { get }
    /// Whether a cell holds a staged (not yet saved) edit.
    func isStaged(row: Int, column: Int) -> Bool
}

extension GridDataSource {
    public func isStaged(row: Int, column: Int) -> Bool { false }
}

/// Header clicks cycle: ascending → descending → no sort.
func nextSort(after current: GridSort?, column: String) -> GridSort? {
    guard let current, current.column == column else { return GridSort(column: column, descending: false) }
    return current.descending ? nil : GridSort(column: column, descending: true)
}

// MARK: - Query results

/// Query results from a forward-only cursor. Pages are fetched ahead of the
/// scroll position, and loading stops at `cap` rows so memory stays bounded.
/// Once everything has arrived, header clicks sort the rows in memory.
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
    /// The failure was a lost connection (the workspace offers Reconnect).
    public private(set) var lostConnection = false
    public private(set) var version = 0
    public private(set) var sort: GridSort?
    /// Row order after a sort; nil keeps the server's order.
    private var order: [Int]?

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

    /// Sorting needs every row; a truncated or still-loading result can't be sorted honestly.
    public var canSort: Bool { isDone && !isTruncated && error == nil }

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
        if order == nil, index >= rows.count - Int(Self.pageSize), !isDone, !isTruncated {
            wanted = max(wanted, index + Int(Self.pageSize) * 2)
            if !isLoading { Task { await fill() } }
        }
        guard index < rows.count else { return nil }
        return rows[order?[index] ?? index]
    }

    /// Cycles the sort on `column` (ascending, descending, off).
    public func toggleSort(column: String) {
        guard canSort, let i = columns.firstIndex(where: { $0.name == column }) else { return }
        sort = nextSort(after: sort, column: column)
        if let sort {
            let desc = sort.descending
            order = rows.indices.sorted { a, b in
                let c = Value.compare(rows[a].cells[i], rows[b].cells[i])
                return c == .orderedSame ? a < b : (desc ? c == .orderedDescending : c == .orderedAscending)
            }
        } else {
            order = nil
        }
        version += 1
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
        if case .Connection? = e as? CoreError { lostConnection = true }
        isDone = true
        version += 1
    }
}

extension Value {
    /// Order for in-memory sorts: NULLs last, numbers numerically, the rest as text.
    public static func compare(_ a: Value, _ b: Value) -> ComparisonResult {
        switch (a, b) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedDescending
        case (_, .null): return .orderedAscending
        default: break
        }
        if let x = a.number, let y = b.number {
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        return a.cellText.localizedStandardCompare(b.cellText)
    }

    var number: Double? {
        switch self {
        case .int(let v): Double(v)
        case .float(let v): v
        case .decimal(let v): Double(v)
        case .bool(let v): v ? 1 : 0
        default: nil
        }
    }
}

// MARK: - Table tabs

/// One page of a table or collection at a time, with First / Prev / Next /
/// Last and server-side sorting. Pages use keyset cursors when the table has
/// a key, so deep pages of a 100M-row table cost the same as the first.
/// Cell edits are staged here until they are reviewed and applied.
@MainActor @Observable
public final class TablePager: GridDataSource {
    public nonisolated static let pageSizes = [50, 100, 500, 1000]

    public private(set) var meta: TableMeta?
    public private(set) var page: TablePage?
    /// 1-based. Approximate after jumping to the last page of an estimated count.
    public private(set) var pageNumber = 1
    public private(set) var count: RowCount?
    public private(set) var sort: GridSort?
    public private(set) var pageSize = 100
    public private(set) var isLoading = false
    public private(set) var isCounting = false
    public private(set) var error: String?
    public private(set) var version = 0
    /// Staged values by row key and column. They survive page changes.
    public private(set) var staged: [StagedCell: Value] = [:]
    /// Original values of staged cells, for the review sheet.
    private var originals: [StagedCell: Value] = [:]

    private var session: Session
    public let path: [String]
    private var cursor: PageCursor = .first

    public struct StagedCell: Hashable {
        public let key: [Value]
        public let column: String
    }

    public init(session: Session, path: [String]) {
        self.session = session
        self.path = path
    }

    // MARK: GridDataSource

    public var columns: [ColumnInfo] { page?.columns ?? [] }
    public var rowCount: Int { page?.rows.count ?? 0 }

    public func row(at index: Int) -> Row? {
        guard let page, index < page.rows.count else { return nil }
        guard !staged.isEmpty, index < page.rowKeys.count else { return page.rows[index] }
        let key = page.rowKeys[index]
        var cells = page.rows[index].cells
        for (i, col) in page.columns.enumerated() where i < cells.count {
            if let v = staged[StagedCell(key: key, column: col.name)] { cells[i] = v }
        }
        return Row(cells: cells)
    }

    public func isStaged(row: Int, column: Int) -> Bool {
        guard let page, row < page.rowKeys.count, column < page.columns.count else { return false }
        return staged[StagedCell(key: page.rowKeys[row], column: page.columns[column].name)] != nil
    }

    // MARK: Loading

    public func start() async {
        do {
            meta = try await session.tableMeta(path: path)
        } catch {
            self.error = describe(error)
        }
        await load(.first, number: 1)
        await refreshCount(exact: false)
    }

    /// Keyset paging is used whenever the page carries keys.
    public var usesKeyset: Bool { page?.firstKey != nil || page?.lastKey != nil }

    public var hasPrev: Bool { page?.hasPrev ?? false }
    public var hasNext: Bool { page?.hasNext ?? false }

    public var pageCount: Int? {
        guard let count, count.count > 0 else { return nil }
        return Int((count.count + UInt64(pageSize) - 1) / UInt64(pageSize))
    }

    /// "201–300", using the page number when the exact offset isn't known.
    public var rangeText: String {
        guard let page, !page.rows.isEmpty else { return "No rows" }
        let start = page.offset.map { Int($0) } ?? (pageNumber - 1) * pageSize
        return "\((start + 1).formatted())–\((start + page.rows.count).formatted())"
    }

    public func first() async { await load(.first, number: 1) }

    public func next() async {
        guard let page, page.hasNext else { return }
        if let key = page.lastKey {
            await load(.after(key: key), number: pageNumber + 1)
        } else {
            await load(.offset(offset: UInt64(pageNumber * pageSize)), number: pageNumber + 1)
        }
    }

    public func prev() async {
        guard let page, page.hasPrev else { return }
        if let key = page.firstKey {
            await load(.before(key: key), number: max(1, pageNumber - 1))
        } else {
            await load(.offset(offset: UInt64(max(0, pageNumber - 2) * pageSize)), number: max(1, pageNumber - 1))
        }
    }

    public func last() async {
        if usesKeyset || (page == nil && meta?.paging == .keyset && sort == nil) {
            await load(.last, number: pageCount ?? pageNumber)
        } else if let pages = pageCount {
            await load(.offset(offset: UInt64((pages - 1) * pageSize)), number: pages)
        }
    }

    /// An explicit jump by offset. Its cost grows with the page number.
    public func goTo(page number: Int) async {
        let n = max(1, number)
        await load(n == 1 ? .first : .offset(offset: UInt64((n - 1) * pageSize)), number: n)
    }

    public func setPageSize(_ size: Int) async {
        guard size != pageSize else { return }
        pageSize = size
        await load(.first, number: 1)
    }

    /// Cycles the server-side sort on `column` and returns to the first page.
    public func toggleSort(column: String) async {
        sort = nextSort(after: sort, column: column)
        await load(.first, number: 1)
    }

    /// Sorting by a column no index leads makes every page scan the table.
    public var sortIsSlow: Bool {
        guard let sort, let meta else { return false }
        return !(meta.columns.first { $0.name == sort.column }?.indexed ?? true)
    }

    public func reload() async {
        await load(cursor, number: pageNumber)
    }

    /// Re-reads metadata and returns to the first page (after schema changes).
    public func refresh() async {
        meta = try? await session.tableMeta(path: path)
        await load(.first, number: 1)
        await refreshCount(exact: count?.exact ?? false)
    }

    public func refreshCount(exact: Bool) async {
        isCounting = true
        defer { isCounting = false }
        do {
            count = try await session.rowCount(path: path, exact: exact)
        } catch {
            if exact { self.error = describe(error) }
        }
        version += 1
    }

    func rebind(_ session: Session) {
        self.session = session
    }

    private func load(_ cursor: PageCursor, number: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let spec = sort.map { SortSpec(column: $0.column, descending: $0.descending) }
            let p = try await session.fetchPage(path: path, cursor: cursor, size: UInt32(pageSize), sort: spec)
            page = p
            self.cursor = cursor
            pageNumber = p.hasPrev ? number : 1
            error = nil
        } catch {
            self.error = describe(error)
        }
        version += 1
    }

    // MARK: Editing

    public var canEdit: Bool { (meta?.editable ?? false) && !(page?.rowKeys.isEmpty ?? true) }

    public func columnMeta(_ name: String) -> ColumnMeta? {
        meta?.columns.first { $0.name == name }
    }

    /// Stages `value` for a cell of the current page. Setting a cell back to
    /// its original value removes the staged change.
    public func stage(row: Int, column: Int, value: Value) {
        guard canEdit, let page, row < page.rowKeys.count, column < page.columns.count else { return }
        let name = page.columns[column].name
        guard columnMeta(name)?.editable ?? false else { return }
        let cell = StagedCell(key: page.rowKeys[row], column: name)
        let original = originals[cell] ?? page.rows[row].cells[column]
        if value == original {
            staged[cell] = nil
            originals[cell] = nil
        } else {
            staged[cell] = value
            originals[cell] = original
        }
        version += 1
    }

    /// Drops the staged change of one cell.
    public func revert(row: Int, column: Int) {
        guard let page, row < page.rowKeys.count, column < page.columns.count else { return }
        let cell = StagedCell(key: page.rowKeys[row], column: page.columns[column].name)
        staged[cell] = nil
        originals[cell] = nil
        version += 1
    }

    public func discardEdits() {
        staged = [:]
        originals = [:]
        version += 1
    }

    public struct PendingChange: Identifiable {
        public let cell: StagedCell
        public let old: Value
        public let new: Value
        public var id: StagedCell { cell }
    }

    /// Staged changes in a stable order, for the review sheet.
    public var pendingChanges: [PendingChange] {
        staged.map { PendingChange(cell: $0.key, old: originals[$0.key] ?? .null, new: $0.value) }
            .sorted { ($0.cell.key.map(\.cellText).joined(), $0.cell.column) < ($1.cell.key.map(\.cellText).joined(), $1.cell.column) }
    }

    var edits: [CellEdit] {
        pendingChanges.map { CellEdit(key: $0.cell.key, column: $0.cell.column, value: $0.new) }
    }

    public func previewStatements() async throws -> [String] {
        try await session.previewEdits(path: path, edits: edits)
    }

    /// Saves every staged change in one transaction, then reloads the page.
    @discardableResult
    public func applyEdits() async throws -> UInt64 {
        let applied = try await session.applyEdits(path: path, edits: edits)
        discardEdits()
        await reload()
        return applied
    }
}

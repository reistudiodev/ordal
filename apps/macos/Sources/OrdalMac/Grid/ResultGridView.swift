import AppKit
import OrdalKit
import SwiftUI

/// A virtualised grid over any `GridDataSource`: NSTableView only asks for
/// visible rows, and the source pages them in from the core.
struct ResultGridView: NSViewRepresentable {
    let source: any GridDataSource
    /// Passed so SwiftUI calls `updateNSView` whenever the source changes.
    let version: Int
    /// Row and column index of a clicked cell.
    var onSelectCell: (Int, Int) -> Void = { _, _ in }
    /// Double-click or Return on a cell (opens the editor).
    var onActivateCell: (Int, Int) -> Void = { _, _ in }
    /// A header click; nil disables sorting.
    var onSortColumn: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.4)
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: Space.s, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.coordinator = context.coordinator
        table.setAccessibilityLabel("Results")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.apply(source)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(source)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResultGridView
        weak var table: NSTableView?
        private var source: (any GridDataSource)?
        private var shownColumns: [ColumnInfo] = []
        private var shownRows = 0
        private var shownSort: GridSort?
        private static let cellID = NSUserInterfaceItemIdentifier("cell")

        init(_ parent: ResultGridView) { self.parent = parent }

        func apply(_ new: any GridDataSource) {
            guard let table else { return }
            let sameSource = source === new
            source = new
            if !sameSource || new.columns != shownColumns {
                rebuildColumns(new.columns)
                shownRows = new.rowCount
                shownSort = new.sort
                table.reloadData()
                showSort(new.sort)
                return
            }
            let sortChanged = shownSort != new.sort
            shownSort = new.sort
            showSort(new.sort)
            if new.rowCount != shownRows {
                shownRows = new.rowCount
                table.noteNumberOfRowsChanged()
            }
            if sortChanged {
                table.reloadData()
            } else {
                // Rows that arrived while they were on screen.
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0, table.numberOfColumns > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
        }

        /// Header arrows for the current sort.
        private func showSort(_ sort: GridSort?) {
            guard let table else { return }
            for (i, tc) in table.tableColumns.enumerated() {
                let index = Int(tc.identifier.rawValue) ?? i
                let name = index < shownColumns.count ? shownColumns[index].name : ""
                let image: NSImage? = sort?.column == name
                    ? NSImage(named: sort!.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator")
                    : nil
                if table.indicatorImage(in: tc) != image { table.setIndicatorImage(image, in: tc) }
            }
            table.highlightedTableColumn = table.tableColumns.first { tc in
                let index = Int(tc.identifier.rawValue) ?? -1
                return index < shownColumns.count && shownColumns[index].name == sort?.column
            }
            table.headerView?.needsDisplay = true
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let onSort = parent.onSortColumn, let i = Int(tableColumn.identifier.rawValue), i < shownColumns.count else { return }
            onSort(shownColumns[i].name)
        }

        private func rebuildColumns(_ columns: [ColumnInfo]) {
            guard let table else { return }
            shownColumns = columns
            for c in table.tableColumns { table.removeTableColumn(c) }
            for (i, col) in columns.enumerated() {
                let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                tc.title = col.name
                tc.headerToolTip = col.typeName.isEmpty ? nil : "\(col.name) · \(col.typeName)"
                tc.minWidth = 48
                tc.width = Self.width(for: col)
                tc.headerCell.alignment = col.kind.isNumeric ? .right : .left
                if parent.onSortColumn != nil {
                    tc.sortDescriptorPrototype = NSSortDescriptor(key: col.name, ascending: true)
                }
                table.addTableColumn(tc)
            }
        }

        private static func width(for col: ColumnInfo) -> CGFloat {
            let header = CGFloat(col.name.count) * 7.5 + 24
            let content: CGFloat = switch col.kind {
            case .bool: 56
            case .int, .float, .decimal: 96
            case .date, .time: 110
            case .timestamp, .timestampTz: 190
            case .uuid: 290
            case .json, .text, .other: 220
            case .bytes: 160
            }
            return min(max(header, content), 420)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            source?.rowCount ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let col = Int(tableColumn.identifier.rawValue), let source else { return nil }
            let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView) ?? Self.makeCell()
            let field = cell.textField!
            let kind = col < source.columns.count ? source.columns[col].kind : .other
            let staged = source.isStaged(row: row, column: col)
            cell.wantsLayer = true
            // Resolve the dynamic colour for this table's appearance (light/dark).
            var background: CGColor?
            if staged { tableView.effectiveAppearance.performAsCurrentDrawingAppearance { background = DataColors.staged.cgColor } }
            cell.layer?.backgroundColor = background
            cell.toolTip = staged ? "Changed, not saved yet" : nil
            if let r = source.row(at: row), col < r.cells.count {
                let value = r.cells[col]
                field.stringValue = value.cellText
                field.textColor = DataColors.color(for: kind, value: value)
                field.font = value.isNull ? Fonts.dataItalic : Fonts.data
                field.alignment = kind.isNumeric ? .right : .left
            } else {
                // Not loaded yet; the source is fetching this page.
                field.stringValue = "…"
                field.textColor = .tertiaryLabelColor
                field.font = Fonts.data
                field.alignment = .left
            }
            return cell
        }

        private static func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = cellID
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        @objc func clicked(_ sender: NSTableView) {
            guard let (row, index) = cell(at: sender) else { return }
            parent.onSelectCell(row, index)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard let (row, index) = cell(at: sender) else { return }
            parent.onSelectCell(row, index)
            parent.onActivateCell(row, index)
        }

        /// The clicked cell as (row, source column index), header clicks excluded.
        private func cell(at sender: NSTableView) -> (Int, Int)? {
            let row = sender.clickedRow, col = sender.clickedColumn
            guard row >= 0, col >= 0, let source else { return nil }
            let index = Int(sender.tableColumns[col].identifier.rawValue) ?? col
            guard index < source.columns.count, source.row(at: row) != nil else { return nil }
            return (row, index)
        }

        /// Selected rows as tab-separated text with a header line.
        func copySelection(from tableView: NSTableView) {
            guard let source else { return }
            let order = tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }
            var lines = [order.map { source.columns[$0].name }.joined(separator: "\t")]
            for row in tableView.selectedRowIndexes {
                guard let r = source.row(at: row) else { continue }
                lines.append(order.map { $0 < r.cells.count ? r.cells[$0].inspectorText : "" }.joined(separator: "\t"))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }
}

/// Adds ⌘C (copy selected rows) to the table.
final class GridTableView: NSTableView {
    weak var coordinator: ResultGridView.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection(from: self)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }
}

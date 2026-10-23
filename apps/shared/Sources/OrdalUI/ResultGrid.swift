import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

public struct ColumnIndexed: Identifiable {
    public let id: Int
    public let column: ColumnInfo

    public init(id: Int, column: ColumnInfo) {
        self.id = id
        self.column = column
    }
}

public struct RowItem: Identifiable {
    public let id: Int
    public let row: Row?

    public init(id: Int, row: Row?) {
        self.id = id
        self.row = row
    }
}

/// Modern native cross-platform database results grid with clean spreadsheet aesthetics and typed cell coloring.
public struct ResultGrid: View {
    let source: any GridDataSource
    var onSelectCell: ((Int, Int) -> Void)?
    var onSortColumn: ((String) -> Void)?

    @State private var selectedRow: Int?
    @State private var selectedCol: Int?

    public init(
        source: any GridDataSource,
        onSelectCell: ((Int, Int) -> Void)? = nil,
        onSortColumn: ((String) -> Void)? = nil
    ) {
        self.source = source
        self.onSelectCell = onSelectCell
        self.onSortColumn = onSortColumn
    }

    private var columnsIndexed: [ColumnIndexed] {
        source.columns.enumerated().map { ColumnIndexed(id: $0.offset, column: $0.element) }
    }

    private var rowsData: [RowItem] {
        let count = min(source.rowCount, 500)
        return (0..<count).map { RowItem(id: $0, row: source.row(at: $0)) }
    }

    private var columnWidths: [Int: Double] {
        var widths: [Int: Double] = [:]
        let sampleCount = min(source.rowCount, 40)
        for colItem in columnsIndexed {
            var maxLen = min(colItem.column.name.count, 25)
            for r in 0..<sampleCount {
                if let row = source.row(at: r), colItem.id < row.cells.count {
                    let len = min(row.cells[colItem.id].cellText.count, 35)
                    if len > maxLen {
                        maxLen = len
                    }
                }
            }
            // Estimate pixel width: ~8.2px per character + 28px padding, bounded between 100 and 260
            let estimated = Double(maxLen) * 8.2 + 28.0
            widths[colItem.id] = min(max(estimated, 100.0), 260.0)
        }
        return widths
    }

    private func totalTableWidth(widths: [Int: Double]) -> Double {
        var total: Double = 0
        for col in columnsIndexed {
            total += (widths[col.id] ?? 120.0)
        }
        if !columnsIndexed.isEmpty {
            total += Double(columnsIndexed.count - 1) * 1.0 // 1px spacing
        }
        return total
    }

    public var body: some View {
        if source.columns.isEmpty {
            VStack {
                Spacer()
                Text("No data to display")
                    .foregroundColor(Color.uiTextMuted)
                    .font(.body)
                Spacer()
            }
        } else {
            GeometryReader { proxy in
                let widths = columnWidths
                let tableWidth = totalTableWidth(widths: widths)
                let availWidth = max(proxy.size.width, 0.0)
                let availHeight = max(proxy.size.height, 0.0)
                let minW = max(tableWidth, availWidth)
                let minH = availHeight

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 1) {
                        GridHeaderView(
                            columns: columnsIndexed,
                            columnWidths: widths,
                            sort: source.sort,
                            onSortColumn: onSortColumn
                        )

                        if source.rowCount == 0 {
                            HStack {
                                Text("(0 rows returned)")
                                    .foregroundColor(Color.uiTextMuted)
                                    .font(.caption)
                                    .padding(12)
                                Spacer()
                            }
                        } else {
                            ForEach(rowsData, id: \.id) { rowItem in
                                let rowIndex = rowItem.id
                                let isRowSelected = selectedRow == rowIndex

                                RowCellsView(
                                    row: rowItem.row,
                                    columns: columnsIndexed,
                                    columnWidths: widths,
                                    rowIndex: rowIndex,
                                    selectedCol: selectedCol,
                                    isRowSelected: isRowSelected,
                                    isStaged: { r, c in source.isStaged(row: r, column: c) },
                                    onSelectCell: { r, c in
                                        selectedRow = r
                                        selectedCol = c
                                        onSelectCell?(r, c)
                                    }
                                )
                                .background(
                                    isRowSelected
                                        ? Color.adaptive(
                                            light: Color.hex(0xDBEAFE),
                                            dark: Color.hex(0x1E2A3C)
                                        )
                                        : (rowIndex % 2 == 0
                                            ? Color.adaptive(
                                                light: Color.hex(0xFFFFFF),
                                                dark: Color.hex(0x111620)
                                            )
                                            : Color.adaptive(
                                                light: Color.hex(0xF8FAFC),
                                                dark: Color.hex(0x151B27)
                                            ))
                                )
                            }
                        }
                    }
                    .frame(minWidth: minW, minHeight: minH, alignment: .topLeading)
                }
            }
            .background(Color.uiBackground)
        }
    }
}

private struct GridHeaderView: View {
    let columns: [ColumnIndexed]
    let columnWidths: [Int: Double]
    let sort: GridSort?
    let onSortColumn: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(columns, id: \.id) { colItem in
                let col = colItem.column
                let isSorted = sort?.column == col.name
                let width = columnWidths[colItem.id] ?? 120.0

                Button {
                    onSortColumn?(col.name)
                } label: {
                    HStack(spacing: 6) {
                        Text(col.name)
                            .font(.system(size: 12))
                            .foregroundColor(
                                isSorted
                                    ? Color.uiAccent
                                    : Color.uiTextPrimary
                            )

                        if isSorted {
                            ModernIcon(
                                sort?.descending == true ? .chevronDown : .chevronUp,
                                color: Color.uiAccent,
                                size: 8,
                                strokeWidth: 1.8
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(
                    isSorted
                        ? Color.adaptive(
                            light: Color.hex(0xE2E8F0),
                            dark: Color.hex(0x242F42)
                        )
                        : Color.adaptive(
                            light: Color.hex(0xF1F5F9),
                            dark: Color.hex(0x1A2230)
                        )
                )
            }
        }
    }
}

private struct RowCellsView: View {
    let row: Row?
    let columns: [ColumnIndexed]
    let columnWidths: [Int: Double]
    let rowIndex: Int
    let selectedCol: Int?
    let isRowSelected: Bool
    let isStaged: (Int, Int) -> Bool
    let onSelectCell: (Int, Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(columns, id: \.id) { colItem in
                let colIndex = colItem.id
                let col = colItem.column
                let val = (row != nil && colIndex < row!.cells.count) ? row!.cells[colIndex] : Value.null
                let isCellSelected = isRowSelected && selectedCol == colIndex
                let staged = isStaged(rowIndex, colIndex)
                let width = columnWidths[colIndex] ?? 120.0

                CellView(
                    value: val,
                    kind: col.kind,
                    width: width,
                    isStaged: staged,
                    isSelected: isCellSelected
                ) {
                    onSelectCell(rowIndex, colIndex)
                }
            }
        }
    }
}

private struct CellView: View {
    let value: Value
    let kind: ValueKind
    let width: Double
    let isStaged: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private var displayText: String {
        let text = value.cellText
        let limit = 35
        if text.count > limit {
            return String(text.prefix(limit)) + "…"
        }
        return text
    }

    var body: some View {
        let role = DataPalette.role(for: kind, value: value)
        let textColor: Color = {
            if let pair = DataPalette.colors(for: role) {
                return Color.from(pair: pair)
            } else if role == .muted {
                return Color.uiTextMuted
            } else {
                return Color.uiTextPrimary
            }
        }()

        Button(displayText) {
            onTap()
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, design: kind.isNumeric ? .monospaced : .default))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: width, alignment: kind.isNumeric ? .trailing : .leading)
        .foregroundColor(textColor)
        .background(
            isStaged
                ? Color.from(pair: DataPalette.staged)
                : (isSelected
                    ? Color.adaptive(
                        light: Color.hex(0xBFDBFE),
                        dark: Color.hex(0x1D4ED8)
                    )
                    : Color.clear)
        )
    }
}

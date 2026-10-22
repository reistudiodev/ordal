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

/// Native cross-platform database results grid with typed cell coloring and header sorting.
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

    public var body: some View {
        if source.columns.isEmpty {
            VStack {
                Spacer()
                Text("No data to display")
                    .foregroundColor(Color(white: 0.5))
                    .font(.body)
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                GridHeaderView(
                    columns: columnsIndexed,
                    sort: source.sort,
                    onSortColumn: onSortColumn
                )

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 1) {
                        if source.rowCount == 0 {
                            HStack {
                                Text("(0 rows returned)")
                                    .foregroundColor(Color(white: 0.5))
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
                                        ? Color.adaptive(light: Color(white: 0.82), dark: Color(white: 0.25))
                                        : (rowIndex % 2 == 0
                                            ? Color.adaptive(light: Color(white: 0.98), dark: Color(white: 0.14))
                                            : Color.adaptive(light: Color(white: 0.93), dark: Color(white: 0.17)))
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct GridHeaderView: View {
    let columns: [ColumnIndexed]
    let sort: GridSort?
    let onSortColumn: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 1) {
                ForEach(columns, id: \.id) { colItem in
                    let col = colItem.column
                    let isSorted = sort?.column == col.name
                    let sortArrow = isSorted ? (sort?.descending == true ? " ↓" : " ↑") : ""

                    Button("\(col.name)\(sortArrow)") {
                        onSortColumn?(col.name)
                    }
                    .frame(minWidth: 120, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Color.adaptive(
                            light: Color(white: 0.88),
                            dark: Color(white: 0.22)
                        )
                    )
                }
            }
        }
    }
}

private struct RowCellsView: View {
    let row: Row?
    let columns: [ColumnIndexed]
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

                CellView(
                    value: val,
                    kind: col.kind,
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
    let isStaged: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        let role = DataPalette.role(for: kind, value: value)
        let textColor: Color = {
            if let pair = DataPalette.colors(for: role) {
                return Color.from(pair: pair)
            } else if role == .muted {
                return Color(white: 0.5)
            } else {
                return Color.adaptive(light: Color(white: 0.1), dark: Color(white: 0.9))
            }
        }()

        Button(value.cellText) {
            onTap()
        }
        .frame(minWidth: 120, alignment: kind.isNumeric ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundColor(textColor)
        .background(
            isStaged
                ? Color.from(pair: DataPalette.staged)
                : (isSelected
                    ? Color.adaptive(light: Color.hex(0xBBDDFF), dark: Color.hex(0x224466))
                    : Color.clear)
        )
    }
}

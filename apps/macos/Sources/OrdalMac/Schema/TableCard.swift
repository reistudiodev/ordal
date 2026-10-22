import AppKit
import OrdalKit
import SwiftUI

/// The glyphs shared by cards and the legend.
enum ColumnGlyph {
    static let primaryKey = "key"
    static let identity = "number"
    static let unique = "touchid"
    static let nullable = "diamond"
    static let notNull = "diamond.fill"
}

/// What a card's menu and hover do, supplied by the diagram.
struct CardActions {
    var open: () -> Void
    var newQuery: () -> Void
    var toggleFocus: () -> Void
    var hide: () -> Void
    var hover: (_ column: String?) -> Void
}

/// A table card: header with ⋮ menu, then every column with its flags and type.
/// It takes plain values and is `Equatable`, so moving one card while
/// dragging re-renders only that card. Dragging and clicks are handled by
/// `DiagramHostingView`; hover and the menu stay here.
struct TableCard: View, Equatable {
    let table: GraphTable
    let position: DiagramPoint
    let emphasis: SchemaTabModel.Emphasis
    let hoveredColumn: String?
    let foreignKeys: Set<String>
    let references: [String]
    let isFocusingThis: Bool
    let actions: CardActions

    static func == (a: TableCard, b: TableCard) -> Bool {
        a.table == b.table && a.position == b.position && a.emphasis == b.emphasis
            && a.hoveredColumn == b.hoveredColumn && a.foreignKeys == b.foreignKeys && a.isFocusingThis == b.isFocusingThis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(table.columns.enumerated()), id: \.offset) { i, c in
                row(c, striped: i % 2 == 1)
            }
        }
        .padding(.bottom, 6)
        .frame(width: SchemaLayout.cardWidth, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(emphasis == .highlighted ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: emphasis == .highlighted ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .opacity(emphasis == .dimmed ? 0.35 : 1)
        .offset(x: position.x, y: position.y)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", actions.open)
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "tablecells").foregroundStyle(.secondary)
            Text(table.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.hairline)
            if let n = table.estimatedRows, n > 0 {
                Text(Self.compact(n))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("About \(n.formatted()) rows")
            }
            Menu {
                Button("Open Data", action: actions.open)
                Button("New Query", action: actions.newQuery)
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.name, forType: .string)
                }
                Divider()
                Button(isFocusingThis ? "Show All Tables" : "Show Only Related", action: actions.toggleFocus)
                Button("Hide Table", action: actions.hide)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20)
            .accessibilityLabel("Actions for \(table.name)")
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: SchemaLayout.headerHeight)
        .background(emphasis == .highlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ c: GraphColumn, striped: Bool) -> some View {
        let hovered = hoveredColumn == c.name
        return HStack(spacing: 6) {
            // Key / identity slot.
            Group {
                if c.isKey {
                    Image(systemName: ColumnGlyph.primaryKey).help("Primary key")
                } else if c.isIdentity {
                    Image(systemName: ColumnGlyph.identity).help("Identity")
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            .foregroundStyle(.secondary)
            Image(systemName: c.nullable ? ColumnGlyph.nullable : ColumnGlyph.notNull)
                .font(.system(size: 8))
                .foregroundStyle(c.nullable ? .secondary : .primary)
                .frame(width: 10)
                .help(c.nullable ? "Nullable" : "Non-nullable")
            if c.isUnique {
                Image(systemName: ColumnGlyph.unique).font(.system(size: 10)).foregroundStyle(.secondary).help("Unique")
            }
            if c.isKey && c.isIdentity {
                Image(systemName: ColumnGlyph.identity).font(.system(size: 9)).foregroundStyle(.secondary).help("Identity")
            }
            Text(c.name)
                .font(.caption)
                .fontWeight(foreignKeys.contains(c.name) ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: Space.hairline)
            Text(c.typeName)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: SchemaLayout.rowHeight)
        .background(hovered ? Color.accentColor.opacity(0.12) : striped ? Color.primary.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                actions.hover(c.name)
            } else if hovered {
                actions.hover(nil)
            }
        }
    }

    private var accessibilityText: String {
        var text = "\(table.name), \(table.columns.count) columns"
        if !references.isEmpty { text += ", references \(references.joined(separator: ", "))" }
        return text
    }

    static func compact(_ n: UInt64) -> String {
        switch n {
        case 1_000_000...: String(format: "~%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "~%.1fK", Double(n) / 1e3)
        default: "\(n)"
        }
    }
}

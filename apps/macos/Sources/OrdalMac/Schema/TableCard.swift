import AppKit
import DBClientKit
import SwiftUI

/// The glyphs shared by cards and the legend.
enum ColumnGlyph {
    static let primaryKey = "key"
    static let identity = "number"
    static let unique = "touchid"
    static let nullable = "diamond"
    static let notNull = "diamond.fill"
}

/// A table card: header with ⋮ menu, then every column with its flags and type.
struct TableCard: View {
    let table: GraphTable
    let tab: SchemaTabModel
    let isForeignKey: (String) -> Bool
    let open: () -> Void
    let newQuery: () -> Void
    @State private var drag: CGSize = .zero

    var body: some View {
        let p = tab.positions[table.name] ?? DiagramPoint(x: 0, y: 0)
        let emphasis = tab.emphasis(ofTable: table.name)
        VStack(alignment: .leading, spacing: 0) {
            header(selected: emphasis == .highlighted)
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
        .offset(x: p.x + drag.width, y: p.y + drag.height)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture { tab.selected = tab.selected == table.name ? nil : table.name }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    tab.move(table.name, to: DiagramPoint(x: p.x + v.translation.width, y: p.y + v.translation.height))
                    drag = .zero
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", open)
    }

    private func header(selected: Bool) -> some View {
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
                Button("Open Data", action: open)
                Button("New Query", action: newQuery)
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.name, forType: .string)
                }
                Divider()
                Button(tab.focusOnly && tab.selected == table.name ? "Show All Tables" : "Show Only Related") {
                    if tab.focusOnly && tab.selected == table.name {
                        tab.focusOnly = false
                    } else {
                        tab.selected = table.name
                        tab.focusOnly = true
                    }
                }
                Button("Hide Table") { tab.hide(table.name) }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(table.name)")
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: SchemaLayout.headerHeight)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ c: GraphColumn, striped: Bool) -> some View {
        let hovered = tab.hovered?.table == table.name && tab.hovered?.column == c.name
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
                .fontWeight(isForeignKey(c.name) ? .semibold : .regular)
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
                tab.hovered = (table.name, c.name)
            } else if tab.hovered?.table == table.name && tab.hovered?.column == c.name {
                tab.hovered = nil
            }
        }
    }

    private var accessibilityText: String {
        var text = "\(table.name), \(table.columns.count) columns"
        let refs = tab.references(of: table.name)
        if !refs.isEmpty { text += ", references \(refs.joined(separator: ", "))" }
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

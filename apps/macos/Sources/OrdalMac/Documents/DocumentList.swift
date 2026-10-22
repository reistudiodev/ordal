import AppKit
import OrdalKit
import SwiftUI

/// MongoDB results as document cards (or pretty JSON), like Compass. Cards
/// are built lazily, so only the ones on screen exist.
struct DocumentList: View {
    let count: Int
    let mode: DocumentViewMode
    /// Extended JSON of a row's document; asking may load more rows.
    let document: (Int) -> String?
    /// Bumped when rows arrive or edits are staged.
    let version: Int
    /// Top-level fields with staged edits, and their new values.
    var staged: (_ row: Int) -> [String: Value] = { _ in [:] }
    /// Clicking a top-level field (opens it in the inspector).
    var onSelectField: ((_ row: Int, _ field: String) -> Void)?

    var body: some View {
        let _ = version
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s) {
                ForEach(0..<count, id: \.self) { i in
                    if let json = document(i) {
                        DocumentCard(json: json, row: i, mode: mode, staged: staged(i), onSelectField: onSelectField)
                    } else {
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
            .padding(Space.m)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
}

/// One document: its fields as `key: value` rows, nested objects and arrays
/// expandable, values coloured by type. Or, in JSON mode, pretty JSON.
private struct DocumentCard: View {
    let json: String
    let row: Int
    let mode: DocumentViewMode
    let staged: [String: Value]
    let onSelectField: ((Int, String) -> Void)?
    @State private var expandAll = false
    @State private var showAllFields = false
    @State private var hovering = false
    static let fieldLimit = 25

    var body: some View {
        let doc = DocValue.parse(json)
        VStack(alignment: .leading, spacing: 0) {
            switch (mode, doc) {
            case (_, nil):
                Text(json).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            case (.json, let doc?):
                Text(doc.prettyText())
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case (_, .object(let fields)?):
                let shown = showAllFields ? fields : Array(fields.prefix(Self.fieldLimit))
                ForEach(Array(shown.enumerated()), id: \.offset) { _, f in
                    FieldRow(key: f.key, value: f.value, depth: 0, expandAll: expandAll,
                             staged: staged[f.key], onSelect: onSelectField.map { select in { select(row, f.key) } })
                }
                if fields.count > Self.fieldLimit && !showAllFields {
                    Button("Show \(fields.count - Self.fieldLimit) more fields") { showAllFields = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, Space.hairline)
                }
            case (_, let doc?):
                Text(doc.preview).font(.system(.callout, design: .monospaced))
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: Space.hairline) {
                    if mode == .documents {
                        Button { expandAll.toggle() } label: {
                            Image(systemName: expandAll ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                        .help(expandAll ? "Collapse all" : "Expand all")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(doc?.prettyText() ?? json, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy document")
                }
                .buttonStyle(.borderless)
                .padding(Space.s)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Document") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc?.prettyText() ?? json, forType: .string)
            }
            Button("Copy as Extended JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(json, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document \(row + 1)")
    }
}

/// `key: value`, with a disclosure arrow for objects and arrays.
private struct FieldRow: View {
    let key: String
    let value: DocValue
    let depth: Int
    let expandAll: Bool
    var staged: Value? = nil
    var onSelect: (() -> Void)?
    @State private var expanded: Bool?

    private var isOpen: Bool { expanded ?? expandAll }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.hairline) {
                if value.isContainer, staged == nil {
                    Button { expanded = !isOpen } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOpen ? "Collapse \(key)" : "Expand \(key)")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text(key + ":")
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                if let staged {
                    Text(staged.cellText)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color(nsColor: DataColors.color(for: .other, value: staged)))
                        .lineLimit(3)
                        .help("Changed, not saved yet")
                } else {
                    Text(value.preview)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Self.color(value))
                        .italic(value == .null)
                        .lineLimit(value.isContainer ? 1 : 3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Space.s)
                Text(value.typeName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .padding(.leading, Double(depth) * 16)
            .padding(.horizontal, Space.hairline)
            .background(staged != nil ? Color(nsColor: DataColors.staged) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }

            if isOpen, staged == nil {
                switch value {
                case .object(let fields):
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                        FieldRow(key: f.key, value: f.value, depth: depth + 1, expandAll: expandAll)
                    }
                case .array(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        FieldRow(key: String(i), value: item, depth: depth + 1, expandAll: expandAll)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    static func color(_ v: DocValue) -> Color {
        switch v {
        case .string: Color(nsColor: DataColors.json)
        case .number, .long, .decimal, .int32, .double: Color(nsColor: DataColors.number)
        case .bool: Color(nsColor: DataColors.bool)
        case .date: Color(nsColor: DataColors.date)
        case .objectId, .binary, .null, .other: .secondary
        case .object, .array: .secondary
        }
    }
}

/// Documents | Table | JSON, remembered across tabs.
struct DocumentModePicker: View {
    @Binding var mode: DocumentViewMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(DocumentViewMode.allCases) { m in
                Label(m.rawValue, systemImage: symbol(m)).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show results as documents, a table, or JSON")
    }

    private func symbol(_ m: DocumentViewMode) -> String {
        switch m {
        case .documents: "doc.text"
        case .table: "tablecells"
        case .json: "curlybraces"
        }
    }
}

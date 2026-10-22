import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

public struct DocumentItem: Identifiable {
    public let id: Int
    public let json: String
    public let doc: DocValue?

    public init(id: Int, json: String) {
        self.id = id
        self.json = json
        self.doc = DocValue.parse(json)
    }
}

/// Native cross-platform MongoDB document viewer supporting Cards, Table, and Pretty JSON.
public struct DocumentListView: View {
    let source: any GridDataSource
    var onSelectField: ((Int, String) -> Void)?

    @State private var mode: DocumentViewMode = .documents

    public init(
        source: any GridDataSource,
        onSelectField: ((Int, String) -> Void)? = nil
    ) {
        self.source = source
        self.onSelectField = onSelectField
    }

    private var documents: [DocumentItem] {
        let count = min(source.rowCount, 100)
        return (0..<count).compactMap { i -> DocumentItem? in
            guard let row = source.row(at: i), let firstCell = row.cells.first else { return nil }
            let jsonText: String = {
                switch firstCell {
                case .json(let s): return s
                case .text(let s): return s
                default: return firstCell.cellText
                }
            }()
            return DocumentItem(id: i, json: jsonText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Mode Selector Bar
            HStack(spacing: 8) {
                Text("View Mode:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))

                Button(mode == .documents ? "● Documents" : "Documents") {
                    mode = .documents
                }

                Button(mode == .json ? "● JSON" : "JSON") {
                    mode = .json
                }

                Button(mode == .table ? "● Table" : "Table") {
                    mode = .table
                }

                Spacer()

                Text("\(documents.count) document(s)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.adaptive(light: Color(white: 0.93), dark: Color(white: 0.17)))

            // Content according to mode
            if mode == .table {
                ResultGrid(source: source)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if documents.isEmpty {
                            Text("No documents loaded")
                                .font(.body)
                                .foregroundColor(Color(white: 0.5))
                                .padding(24)
                        } else {
                            ForEach(documents, id: \.id) { item in
                                DocumentCardView(item: item, mode: mode, onSelectField: onSelectField)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct DocumentCardView: View {
    let item: DocumentItem
    let mode: DocumentViewMode
    let onSelectField: ((Int, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Document Header
            HStack {
                Text("Document #\(item.id + 1)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
                Spacer()
            }
            .padding(.bottom, 2)

            if mode == .json {
                // Pretty JSON mode
                let text = item.doc?.prettyText() ?? item.json
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.9))
            } else {
                // Hierarchical / Card mode
                if let doc = item.doc, case .object(let fields) = doc {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(fields, id: \.key) { f in
                            HStack(alignment: .top, spacing: 8) {
                                Button("\(f.key):") {
                                    onSelectField?(item.id, f.key)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.hex(0x007ACC))

                                Text(f.value.preview)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(colorForDoc(f.value))

                                Spacer()

                                Text(f.value.typeName)
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.vertical, 1)
                        }
                    }
                } else {
                    Text(item.json)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .padding(12)
        .background(Color.adaptive(light: Color(white: 0.96), dark: Color(white: 0.19)))
        .cornerRadius(6)
    }

    private func colorForDoc(_ v: DocValue) -> Color {
        switch v {
        case .string: return Color.from(pair: DataPalette.json)
        case .number, .long, .decimal, .int32, .double: return Color.from(pair: DataPalette.number)
        case .bool: return Color.from(pair: DataPalette.bool)
        case .date: return Color.from(pair: DataPalette.date)
        case .null: return Color(white: 0.5)
        default: return Color(white: 0.8)
        }
    }
}

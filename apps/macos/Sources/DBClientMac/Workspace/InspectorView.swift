import AppKit
import DBClientKit
import SwiftUI

/// Full value of the selected cell: pretty JSON, long text, hex bytes.
struct InspectorView: View {
    let workspace: WorkspaceModel

    var body: some View {
        if let cell = workspace.inspected {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.column.name).font(.headline)
                        Text("\(cell.column.typeName.isEmpty ? "\(cell.column.kind)" : cell.column.typeName) · row \(cell.row + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cell.value.inspectorText, forType: .string)
                    }
                    .controlSize(.small)
                }
                Divider()
                ScrollView {
                    Text(cell.value.inspectorText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(cell.value.isNull ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Space.m)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right", description: Text("Click a cell in the results to see its full value."))
        }
    }
}

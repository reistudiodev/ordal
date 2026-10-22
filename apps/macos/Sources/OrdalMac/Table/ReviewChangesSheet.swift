import OrdalKit
import SwiftUI

/// Every staged edit (old → new) and the exact statements that will run.
/// Applying runs them in one transaction; on production the database name
/// must be typed first.
struct ReviewChangesSheet: View {
    let pager: TablePager
    let config: ConnectionConfig
    let dismiss: () -> Void
    @State private var statements: [String] = []
    @State private var previewError: String?
    @State private var applyError: String?
    @State private var applying = false
    @State private var typed = ""

    private var strong: Bool { config.environment == .prod }
    private var expected: String { config.database.isEmpty ? config.name : config.database }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: strong ? "exclamationmark.triangle.fill" : "square.and.pencil")
                    .font(.title2)
                    .foregroundStyle(strong ? EnvironmentTag.prod.color : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review \(pager.staged.count) \(pager.staged.count == 1 ? "change" : "changes")").font(.headline)
                    Text("\(pager.path.last ?? "") · \(config.name)\(strong ? " · Production" : "")")
                        .foregroundStyle(.secondary)
                }
            }

            Table(pager.pendingChanges) {
                TableColumn("Row") { Text($0.cell.key.map(\.cellText).joined(separator: ", ")).font(.callout.monospaced()) }
                    .width(min: 60, ideal: 90)
                TableColumn("Column") { Text($0.cell.column).font(.callout.monospaced()) }
                    .width(min: 80, ideal: 120)
                TableColumn("Before") { Text($0.old.cellText).font(.callout.monospaced()).foregroundStyle(.secondary) }
                TableColumn("After") { Text($0.new.cellText).font(.callout.monospaced()) }
            }
            .frame(minHeight: 140)

            Text(config.kind == .mongoDb ? "Commands" : "SQL").font(.subheadline.weight(.semibold))
            ScrollView {
                Text(previewError ?? statements.joined(separator: ";\n") + (statements.isEmpty ? "" : ";"))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(previewError == nil ? .primary : Color.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
            }
            .frame(minHeight: 100, maxHeight: 180)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            if strong {
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text("Type **\(expected)** to apply these changes on production.")
                    TextField(expected, text: $typed).textFieldStyle(.roundedBorder).font(.body.monospaced())
                }
            }
            if let applyError {
                Label(applyError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Text(config.kind == .mongoDb
                     ? "Applied one by one; every document is checked first."
                     : "Applied in one transaction: all of them, or none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(applying ? "Applying…" : "Apply Changes", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || previewError != nil || (strong && typed != expected))
            }
        }
        .padding(Space.l)
        .frame(width: 640)
        .task {
            do {
                statements = try await pager.previewStatements()
            } catch {
                previewError = describe(error)
            }
        }
    }

    private func apply() {
        applying = true
        applyError = nil
        Task {
            do {
                try await pager.applyEdits()
                dismiss()
            } catch {
                applyError = describe(error)
            }
            applying = false
        }
    }
}

import DBClientKit
import SwiftUI

/// Shown before destructive statements, and before writes on production.
/// On production the user types the database name to confirm.
struct ConfirmStatementSheet: View {
    let pending: QueryTabModel.PendingConfirmation
    let config: ConnectionConfig
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var typed = ""

    private var canRun: Bool { !pending.strong || typed == pending.expectedText }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(pending.strong ? EnvironmentTag.prod.color : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.strong ? "Run on production?" : "Run this statement?").font(.headline)
                    Text(pending.reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.s) {
                Circle().fill(config.accent).frame(width: 8, height: 8)
                Text("\(config.name) · \(config.environment.label)").font(.callout)
            }
            ScrollView {
                Text(pending.sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
            }
            .frame(maxHeight: 160)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            if pending.strong {
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text("Type **\(pending.expectedText)** to confirm.")
                    TextField(pending.expectedText, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }

            HStack {
                Spacer()
                // Cancel is the default: Return never runs a destructive statement.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                Button("Run", role: .destructive, action: onConfirm)
                    .disabled(!canRun)
            }
        }
        .padding(Space.l)
        .frame(width: 480)
    }
}

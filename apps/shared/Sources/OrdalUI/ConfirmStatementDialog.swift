import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform destructive statement and production safety confirmation dialog.
public struct ConfirmStatementDialog: View {
    let pending: QueryTabModel.PendingConfirmation
    let config: ConnectionConfig
    let onConfirm: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void
    @State private var typed: String = ""

    public init(
        pending: QueryTabModel.PendingConfirmation,
        config: ConnectionConfig,
        onConfirm: @escaping @MainActor @Sendable () -> Void,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        self.pending = pending
        self.config = config
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var canRun: Bool {
        !pending.strong || typed.trimmingCharacters(in: .whitespaces) == pending.expectedText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Warning header
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.strong ? "⚠️ Run on Production Database?" : "⚠️ Confirm Destructive Query")
                    .font(.title2)
                    .foregroundColor(Color.hex(0xDC3545))
                Text(pending.reason)
                    .font(.body)
                    .foregroundColor(Color(white: 0.6))
            }

            // Target connection badge
            HStack(spacing: 8) {
                Circle()
                    .foregroundColor(Color.from(pair: config.accentColors))
                    .frame(width: 8, height: 8)
                Text("\(config.name) · \(config.environment.label)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))
            }

            // SQL preview
            ScrollView(.vertical) {
                Text(pending.sql)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(
                Color.adaptive(
                    light: Color(white: 0.9),
                    dark: Color(white: 0.12)
                )
            )
            .cornerRadius(6)

            // Production verification input
            if pending.strong {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type \"\(pending.expectedText)\" below to confirm:")
                        .font(.caption)
                    TextField(pending.expectedText, text: $typed)
                }
            }

            // Action Buttons
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Execute Statement") {
                    if canRun {
                        onConfirm()
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460)
    }
}

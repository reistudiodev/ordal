import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern confirmation dialog for destructive or production database statements.
public struct ConfirmStatementDialog: View {
    let pending: QueryTabModel.PendingConfirmation
    let config: ConnectionConfig
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var typed: String = ""

    public init(
        pending: QueryTabModel.PendingConfirmation,
        config: ConnectionConfig,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
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
            HStack(spacing: 12) {
                ModernIcon(.warning, color: Color.uiDanger, size: 24, strokeWidth: 1.8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pending.strong ? "Run on Production Database?" : "Confirm Destructive Query")
                        .font(.title2)
                        .foregroundColor(Color.uiDanger)
                    Text(pending.reason)
                        .font(.body)
                        .foregroundColor(Color.uiTextMuted)
                }
            }

            // Target connection badge
            HStack(spacing: 8) {
                Circle()
                    .foregroundColor(Color.from(pair: config.accentColors))
                    .frame(width: 8, height: 8)
                Text("\(config.name) · \(config.environment.label)")
                    .font(.caption)
                    .foregroundColor(Color.uiTextPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.uiPanel)
            .cornerRadius(4)

            // SQL preview
            ScrollView(.vertical) {
                Text(pending.sql)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color.uiTextPrimary)
                    .padding(10)
            }
            .frame(maxHeight: 140)
            .background(Color.uiSidebar)
            .cornerRadius(6)

            // Production verification input
            if pending.strong {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type \"\(pending.expectedText)\" below to confirm:")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                    TextField(pending.expectedText, text: $typed)
                }
            }

            // Action Buttons
            HStack(spacing: 10) {
                Spacer()

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.uiPanel)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button {
                    if canRun {
                        onConfirm()
                    }
                } label: {
                    Text("Execute Statement")
                        .font(.body)
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(canRun ? Color.uiDanger : Color(white: 0.3))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!canRun)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .background(Color.uiBackground)
        .cornerRadius(8)
    }
}

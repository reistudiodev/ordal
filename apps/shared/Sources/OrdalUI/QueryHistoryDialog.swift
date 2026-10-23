import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern dialog presenting query history with one-click editor reuse and memory clearance.
public struct QueryHistoryDialog: View {
    let container: AppStateContainer
    let tab: QueryTabModel
    let onDismiss: () -> Void

    public init(
        container: AppStateContainer,
        tab: QueryTabModel,
        onDismiss: @escaping () -> Void
    ) {
        self.container = container
        self.tab = tab
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ModernIcon(.history, color: Color.uiAccent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Query History")
                        .font(.title3)
                        .foregroundColor(Color.uiTextPrimary)
                    Text("\(tab.history.count) query(ies) recorded")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                }
                Spacer()

                if !tab.history.isEmpty {
                    Button {
                        tab.clearHistory()
                        container.notifyUpdate()
                    } label: {
                        Text("Clear History")
                            .font(.caption)
                            .foregroundColor(Color.uiDanger)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.uiPanel)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onDismiss()
                } label: {
                    ModernIcon(.close, color: Color.uiTextMuted, size: 11)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if tab.history.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("No query history yet for this connection.")
                            .font(.body)
                            .foregroundColor(Color.uiTextMuted)
                            .padding(24)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(tab.history.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    HStack(spacing: 4) {
                                        ModernIcon(
                                            entry.succeeded ? .checkmark : .close,
                                            color: entry.succeeded ? Color.uiSuccess : Color.uiDanger,
                                            size: 10
                                        )
                                        Text(entry.succeeded ? "Success" : "Failed")
                                            .font(.caption)
                                            .foregroundColor(entry.succeeded ? Color.uiSuccess : Color.uiDanger)
                                    }

                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(Color.uiTextFaint)

                                    Text("\(entry.durationMs) ms")
                                        .font(.caption)
                                        .foregroundColor(Color.uiTextMuted)

                                    if let rows = entry.rows {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundColor(Color.uiTextFaint)
                                        Text("\(rows) row(s)")
                                            .font(.caption)
                                            .foregroundColor(Color.uiTextMuted)
                                    }

                                    Spacer()

                                    Button {
                                        tab.text = entry.query
                                        onDismiss()
                                        container.notifyUpdate()
                                    } label: {
                                        Text("Use Query")
                                            .font(.caption)
                                            .foregroundColor(Color.uiAccent)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.uiPanel)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(entry.query)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color.uiTextPrimary)
                                    .padding(8)
                                    .background(Color.uiBackground)
                                    .cornerRadius(4)
                            }
                            .padding(10)
                            .background(Color.uiPanel)
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 580, height: 420)
        .background(Color.uiBackground)
        .cornerRadius(8)
    }
}

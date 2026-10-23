import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Dialog presenting query history with one-click editor reuse and memory clearance.
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
            HStack(spacing: 8) {
                Text("📜")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Query History")
                        .font(.title3)
                    Text("\(tab.history.count) query(ies) recorded")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.6))
                }
                Spacer()

                if !tab.history.isEmpty {
                    Button("🗑 Clear History") {
                        tab.clearHistory()
                        container.notifyUpdate()
                    }
                    .foregroundColor(Color.hex(0xDC3545))
                }

                Button("✕") {
                    onDismiss()
                }
            }

            Divider()

            if tab.history.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("No query history yet for this connection.")
                            .font(.body)
                            .foregroundColor(Color(white: 0.5))
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
                                    Text(entry.succeeded ? "✓ Success" : "✗ Failed")
                                        .font(.caption)
                                        .foregroundColor(entry.succeeded ? Color.hex(0x28A745) : Color.hex(0xDC3545))

                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.5))

                                    Text("\(entry.durationMs) ms")
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.6))

                                    if let rows = entry.rows {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundColor(Color(white: 0.5))
                                        Text("\(rows) row(s)")
                                            .font(.caption)
                                            .foregroundColor(Color(white: 0.6))
                                    }

                                    Spacer()

                                    Button("Use Query") {
                                        tab.text = entry.query
                                        onDismiss()
                                        container.notifyUpdate()
                                    }
                                }

                                Text(entry.query)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        Color.adaptive(
                                            light: Color(white: 0.96),
                                            dark: Color(white: 0.14)
                                        )
                                    )
                            }
                            .padding(8)
                            .background(
                                Color.adaptive(
                                    light: Color(white: 0.92),
                                    dark: Color(white: 0.22)
                                )
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 580, height: 420)
        .background(
            Color.adaptive(
                light: Color(white: 0.98),
                dark: Color(white: 0.18)
            )
        )
    }
}

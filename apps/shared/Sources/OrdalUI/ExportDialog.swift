import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform export modal dialog for Linux, Windows, and macOS.
public struct ExportDialog: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let target: ExportTarget
    let onDismiss: @MainActor @Sendable () -> Void

    @State private var content: ExportContent = .both
    @State private var format: ExportFormat = .sql
    @State private var limit: ExportLimit = .all
    @State private var isProcessing = false
    @State private var progressMessage: String = ""
    @State private var statusMessage: String = ""
    @State private var exportPreview: String = ""

    public init(
        container: AppStateContainer,
        workspace: WorkspaceModel,
        target: ExportTarget,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.container = container
        self.workspace = workspace
        self.target = target
        self.onDismiss = onDismiss
    }

    private var engine: DatabaseKind { workspace.config.kind }

    private var availableFormats: [ExportFormat] {
        ExportService.availableFormats(engine: engine, isContainer: target.isContainer)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Text(headerIcon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export \(target.name)")
                        .font(.title3)
                    Text("\(engine.label) · \(target.displayTitle)")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.6))
                }
                Spacer()
                Button("✕") {
                    onDismiss()
                }
            }

            Divider()

            // Mode Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("What to Export:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))

                HStack(spacing: 6) {
                    ForEach(ExportContent.allCases) { mode in
                        let isSelected = content == mode
                        Button(mode.rawValue) {
                            content = mode
                            container.notifyUpdate()
                        }
                        .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.7))
                    }
                }

                Text(content.description)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }

            // Format Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("File Format:")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.7))

                HStack(spacing: 6) {
                    ForEach(availableFormats) { f in
                        let isSelected = format == f
                        Button(f.rawValue) {
                            format = f
                            container.notifyUpdate()
                        }
                        .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.7))
                    }
                }
            }

            // Limit Selector
            if content != .structureOnly {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Record Limit:")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.7))

                    HStack(spacing: 6) {
                        ForEach(ExportLimit.allCases) { l in
                            let isSelected = limit == l
                            Button(l.rawValue) {
                                limit = l
                                container.notifyUpdate()
                            }
                            .foregroundColor(isSelected ? Color.hex(0x007ACC) : Color(white: 0.7))
                        }
                    }
                }
            }

            // Status / Preview area
            if isProcessing {
                HStack(spacing: 8) {
                    Text("⏳")
                    Text(progressMessage.isEmpty ? "Generating export..." : progressMessage)
                        .font(.caption)
                        .foregroundColor(Color(white: 0.6))
                }
                .padding(.vertical, 4)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(Color.hex(0x28A745))
                    .padding(.vertical, 4)
            }

            if !exportPreview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview (first 1,000 characters):")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.5))

                    ScrollView(.vertical) {
                        Text(exportPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                    .background(
                        Color.adaptive(
                            light: Color(white: 0.92),
                            dark: Color(white: 0.12)
                        )
                    )
                    .cornerRadius(6)
                }
            }

            Divider()

            // Footer Actions
            HStack {
                Button("Cancel") {
                    onDismiss()
                }

                Spacer()

                Button("Export to File") {
                    Task {
                        await runExport(writeToFile: true)
                    }
                }

                Button("Generate Preview") {
                    Task {
                        await runExport(writeToFile: false)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    private var headerIcon: String {
        switch target.kind {
        case .table: "📄"
        case .view: "👁️"
        case .collection: "📚"
        case .database: "🗄️"
        case .schema: "📁"
        }
    }

    private func runExport(writeToFile: Bool) async {
        isProcessing = true
        statusMessage = ""
        progressMessage = "Preparing export..."
        container.notifyUpdate()

        let options = ExportOptions(content: content, format: format, limit: limit)

        do {
            let output = try await ExportService.export(
                session: workspace.session,
                engine: engine,
                target: target,
                options: options
            ) { progress in
                Task { @MainActor in
                    progressMessage = progress
                    container.notifyUpdate()
                }
            }

            isProcessing = false
            exportPreview = String(output.prefix(1000))

            if writeToFile {
                let suffix = content == .structureOnly ? "_schema" : (content == .dataOnly ? "_data" : "_backup")
                let filename = "\(target.name)\(suffix).\(format.fileExtension)"
                let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let targetURL = downloadsURL.appendingPathComponent(filename)

                try output.write(to: targetURL, atomically: true, encoding: .utf8)
                statusMessage = "✓ Saved to \(targetURL.path)"
            } else {
                statusMessage = "✓ Export generated successfully (\(output.count) bytes)"
            }

            container.notifyUpdate()
        } catch {
            isProcessing = false
            statusMessage = "Export failed: \(error.localizedDescription)"
            container.notifyUpdate()
        }
    }
}

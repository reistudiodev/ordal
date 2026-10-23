import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern native cross-platform export dialog (SQL dump, CSV, JSON, BSON/Mongo).
public struct ExportDialog: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let target: ExportTarget
    let onDismiss: () -> Void

    @State private var content: ExportContent = .both
    @State private var format: ExportFormat = .sql
    @State private var limit: ExportLimit = .all
    @State private var isProcessing: Bool = false
    @State private var progressMessage: String = ""
    @State private var statusMessage: String = ""
    @State private var exportPreview: String = ""

    public init(
        container: AppStateContainer,
        workspace: WorkspaceModel,
        target: ExportTarget,
        onDismiss: @escaping () -> Void
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
            HStack(spacing: 10) {
                ModernIcon(iconType(for: target.kind), color: iconColor(for: target.kind), size: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Export \(target.name)")
                        .font(.title3)
                        .foregroundColor(Color.uiTextPrimary)
                    Text("\(engine.label) · \(target.displayTitle)")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    ModernIcon(.close, color: Color.uiTextMuted, size: 11)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Mode Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("What to Export:")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)

                HStack(spacing: 6) {
                    ForEach(ExportContent.allCases) { mode in
                        let isSelected = content == mode
                        Button {
                            content = mode
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption)
                                .foregroundColor(isSelected ? Color.white : Color.uiTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.uiAccent : Color.uiPanel)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Format Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Export Format:")
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)

                HStack(spacing: 6) {
                    ForEach(availableFormats) { fmt in
                        let isSelected = format == fmt
                        Button {
                            format = fmt
                        } label: {
                            Text(fmt.rawValue)
                                .font(.caption)
                                .foregroundColor(isSelected ? Color.white : Color.uiTextPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.uiAccent : Color.uiPanel)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Row limit for tables
            if !target.isContainer && content != .structureOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Row Limit:")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)

                    HStack(spacing: 6) {
                        ForEach(ExportLimit.allCases) { lim in
                            let isSelected = limit == lim
                            Button {
                                limit = lim
                            } label: {
                                Text(lim.rawValue)
                                    .font(.caption)
                                    .foregroundColor(isSelected ? Color.white : Color.uiTextPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.uiAccent : Color.uiPanel)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Status / Progress
            if isProcessing {
                HStack(spacing: 8) {
                    ModernIcon(.refresh, color: Color.uiAccent, size: 12)
                    Text(progressMessage)
                        .font(.caption)
                        .foregroundColor(Color.uiAccent)
                }
                .padding(.vertical, 4)
            } else if !statusMessage.isEmpty {
                HStack(spacing: 6) {
                    ModernIcon(.checkmark, color: Color.uiSuccess, size: 12)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(Color.uiSuccess)
                }
                .padding(.vertical, 4)
            }

            // Preview pane if generated
            if !exportPreview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview (first 1,000 characters):")
                        .font(.caption)
                        .foregroundColor(Color.uiTextMuted)

                    ScrollView([.horizontal, .vertical]) {
                        Text(exportPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color.uiTextPrimary)
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                    .background(Color.uiSidebar)
                    .cornerRadius(4)
                }
            }

            Divider()

            // Actions
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Text("Close")
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.uiPanel)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task {
                        await runExport(writeToFile: false)
                    }
                } label: {
                    Text("Generate Preview")
                        .font(.body)
                        .foregroundColor(Color.uiTextPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.uiPanel)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)

                Button {
                    Task {
                        await runExport(writeToFile: true)
                    }
                } label: {
                    HStack(spacing: 5) {
                        ModernIcon(.export, color: Color.white, size: 12)
                        Text("Export to File")
                            .font(.body)
                            .foregroundColor(Color.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.uiAccent)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .background(Color.uiBackground)
        .cornerRadius(8)
    }

    private func iconType(for kind: ExportTarget.Kind) -> IconType {
        switch kind {
        case .table: .table
        case .view: .view
        case .collection: .table
        case .database: .database
        case .schema: .schema
        }
    }

    private func iconColor(for kind: ExportTarget.Kind) -> Color {
        switch kind {
        case .table: Color.nodeTable
        case .view: Color.nodeView
        case .collection: Color.nodeTable
        case .database: Color.nodeDatabase
        case .schema: Color.nodeFolder
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

                try output.write(to: targetURL, atomically: true, encoding: String.Encoding.utf8)
                statusMessage = "Saved to \(targetURL.path)"
            } else {
                statusMessage = "Export generated successfully (\(output.count) bytes)"
            }

            container.notifyUpdate()
        } catch {
            isProcessing = false
            statusMessage = "Export failed: \(error.localizedDescription)"
            container.notifyUpdate()
        }
    }
}

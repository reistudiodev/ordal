import AppKit
import OrdalKit
import SwiftUI

/// Modern, clean modal sheet for exporting a table, collection, schema, or entire database.
struct ExportDialogSheet: View {
    @Bindable var workspace: WorkspaceModel
    let target: ExportTarget
    let onDismiss: () -> Void

    @State private var content: ExportContent = .both
    @State private var format: ExportFormat = .sql
    @State private var limit: ExportLimit = .all
    @State private var isProcessing = false
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var copiedSuccess = false

    private var engine: DatabaseKind { workspace.config.kind }

    private var availableFormats: [ExportFormat] {
        ExportService.availableFormats(engine: engine, isContainer: target.isContainer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            // Header
            HStack(spacing: Space.m) {
                Image(systemName: iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.title3.weight(.semibold))
                    Text("\(engine.label) · \(target.displayTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Export Content Mode
            VStack(alignment: .leading, spacing: Space.s) {
                Text("What to Export")
                    .font(.subheadline.weight(.medium))

                Picker("Mode", selection: $content) {
                    ForEach(ExportContent.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(content.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Export Format
            VStack(alignment: .leading, spacing: Space.s) {
                Text("File Format")
                    .font(.subheadline.weight(.medium))

                Picker("Format", selection: $format) {
                    ForEach(availableFormats) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Record Limit (when data is included)
            if content != .structureOnly {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Record Limit")
                        .font(.subheadline.weight(.medium))

                    Picker("Limit", selection: $limit) {
                        ForEach(ExportLimit.allCases) { l in
                            Text(l.rawValue).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // Progress or Error or Success indicator
            if isProcessing {
                HStack(spacing: Space.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage ?? "Generating export...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Space.hairline)
            } else if let error = errorMessage {
                HStack(spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if copiedSuccess {
                HStack(spacing: Space.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Export content copied to clipboard!")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer(minLength: 0)
            Divider()

            // Action Buttons
            HStack(spacing: Space.s) {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Copy to Clipboard") {
                    Task { await performExport(copyOnly: true) }
                }
                .disabled(isProcessing)

                Button("Save to File…") {
                    Task { await performExport(copyOnly: false) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding(Space.l)
        .frame(width: 480, height: 390)
        .onAppear {
            if !availableFormats.contains(format), let first = availableFormats.first {
                format = first
            }
        }
        .onChange(of: content) {
            if !availableFormats.contains(format), let first = availableFormats.first {
                format = first
            }
        }
    }

    private var iconName: String {
        switch target.kind {
        case .table: "tablecells"
        case .view: "eye"
        case .collection: "shippingbox"
        case .database: "cylinder.split.1x2"
        case .schema: "folder"
        }
    }

    private var titleText: String {
        switch target.kind {
        case .table: "Export Table"
        case .view: "Export View"
        case .collection: "Export Collection"
        case .database: "Export Database"
        case .schema: "Export Schema"
        }
    }

    private func performExport(copyOnly: Bool) async {
        isProcessing = true
        errorMessage = nil
        copiedSuccess = false
        progressMessage = "Preparing export..."

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
                }
            }

            isProcessing = false

            if copyOnly {
                ExportHelper.copy(text: output)
                copiedSuccess = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    onDismiss()
                }
            } else {
                let suffix: String
                switch content {
                case .structureOnly: suffix = "_schema"
                case .dataOnly: suffix = "_data"
                case .both: suffix = "_backup"
                }
                let defaultName = "\(target.name)\(suffix)"
                ExportHelper.saveFile(
                    content: output,
                    defaultName: defaultName,
                    fileExtension: format.fileExtension
                )
                onDismiss()
            }
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }
}

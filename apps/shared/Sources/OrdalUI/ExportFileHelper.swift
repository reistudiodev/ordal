import Foundation
import SwiftCrossUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Cross-platform helper for exporting data to files and copying to clipboard.
public enum ExportFileHelper {
    /// Saves text content to a file.
    /// Prompts with native Save panel on macOS, or uses SwiftCrossUI file dialog / Downloads directory.
    @MainActor
    public static func saveFile(
        content: String,
        defaultName: String,
        fileExtension: String,
        saveAction: PresentFileSaveDialogAction? = nil
    ) async -> (success: Bool, message: String) {
        let fullName = "\(defaultName).\(fileExtension)"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = fullName
        switch fileExtension.lowercased() {
        case "csv":
            panel.allowedContentTypes = [.commaSeparatedText]
        case "json":
            panel.allowedContentTypes = [.json]
        case "sql":
            if let sql = UTType(filenameExtension: "sql") {
                panel.allowedContentTypes = [sql, .plainText]
            } else {
                panel.allowedContentTypes = [.plainText]
            }
        default:
            panel.allowedContentTypes = [.plainText]
        }

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return (true, "Exported \(url.lastPathComponent)")
            } catch {
                return (false, "Save error: \(error.localizedDescription)")
            }
        }
        return (false, "")
        #else
        if let saveAction = saveAction {
            if let targetURL = await saveAction(
                title: "Export \(fullName)",
                defaultFileName: fullName
            ) {
                do {
                    try content.write(to: targetURL, atomically: true, encoding: .utf8)
                    return (true, "Exported \(targetURL.lastPathComponent)")
                } catch {
                    return (false, "Save error: \(error.localizedDescription)")
                }
            }
            return (false, "")
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let targetURL = downloads.appendingPathComponent(fullName)
        do {
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
            return (true, "Saved to \(targetURL.path)")
        } catch {
            return (false, "Save error: \(error.localizedDescription)")
        }
        #endif
    }

    /// Copies string to clipboard.
    @MainActor
    public static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

import AppKit
import UniformTypeIdentifiers

/// Reusable helper for exporting data to files and copying to clipboard on macOS.
enum ExportHelper {
    static func saveFile(content: String, defaultName: String, fileExtension: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = "\(defaultName).\(fileExtension)"
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
        case "js":
            panel.allowedContentTypes = [.javaScript, .plainText]
        default:
            panel.allowedContentTypes = [.plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

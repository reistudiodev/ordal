import AppKit
import DBClientKit
import UniformTypeIdentifiers

/// Save and open query files with the standard panels, so you choose the folder.
@MainActor
enum QueryFiles {
    private static var types: [UTType] {
        [UTType(filenameExtension: "sql"), UTType(filenameExtension: "json"), .plainText].compactMap { $0 }
    }

    /// Saves to the tab's file, or asks where when it has none yet.
    static func save(_ tab: QueryTabModel) {
        do {
            if try !tab.save() { saveAs(tab) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func saveAs(_ tab: QueryTabModel) {
        let panel = NSSavePanel()
        panel.title = "Save Query"
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (tab.fileURL?.lastPathComponent) ?? "\(tab.title).sql"
        if let dir = tab.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try tab.save(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func open(in workspace: WorkspaceModel) {
        let panel = NSOpenPanel()
        panel.title = "Open Query"
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try workspace.openFile(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

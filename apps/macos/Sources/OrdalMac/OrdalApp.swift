import AppKit
import DBClientKit
import OSLog
import SwiftUI

/// Startup is measured from `init` to the first frame (target: under 1 s).
enum Startup {
    static let signposter = OSSignposter(subsystem: "dev.dbclient.mac", category: "startup")
    static let log = Logger(subsystem: "dev.dbclient.mac", category: "startup")
    static let began = Date()
    static var state: OSSignpostIntervalState?

    static func finish() {
        guard let s = state else { return }
        signposter.endInterval("launch", s)
        state = nil
        log.info("first frame after \(Int(Date().timeIntervalSince(began) * 1000)) ms")
    }
}

@main
struct DBClientMacApp: App {
    @State private var app = AppState()

    init() {
        Startup.state = Startup.signposter.beginInterval("launch")
        // Launched with `swift run` there is no .app bundle, so tell AppKit
        // this is a regular app that gets a Dock icon and a focused window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.appearance = AppTheme.current.nsAppearance
    }

    var body: some Scene {
        WindowGroup("DB Client") {
            RootView()
                .environment(app)
        }
        .defaultSize(width: 1320, height: 840)
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let app: AppState
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system.rawValue

    private var workspace: WorkspaceModel? { app.activeWorkspace }
    private var query: QueryTabModel? { workspace?.activeEditor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { app.newConnection() }
                .keyboardShortcut("n")
            Button("New Query Tab") { workspace?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Open SQL File…") { if let ws = workspace { QueryFiles.open(in: ws) } }
                .keyboardShortcut("o")
                .disabled(workspace == nil)
            Button("Close Tab") {
                if let id = workspace?.selectedTabID { workspace?.closeTab(id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTabID == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Query") { if let q = query { QueryFiles.save(q) } }
                .keyboardShortcut("s")
                .disabled(query == nil)
            Button("Save Query As…") { if let q = query { QueryFiles.saveAs(q) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(query == nil)
        }
        CommandMenu("Query") {
            Button("Run") { if let q = query { Task { await q.run() } } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(query == nil)
            Button("Cancel") { query?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(query?.isRunning != true)
            Divider()
            Button("Format") { query?.format() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(query == nil || workspace?.config.kind.isSQL != true)
        }
        CommandGroup(after: .sidebar) {
            Picker("Appearance", selection: Binding(get: { theme }, set: { theme = $0; AppTheme.set(AppTheme(rawValue: $0) ?? .system) })) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Divider()
            Button("Command Palette…") { app.showPalette.toggle() }
                .keyboardShortcut("k")
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Connection") {
            Button("Switch Connection…") { app.showPalette = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Edit Connection…") { if let c = workspace?.config { app.edit(c) } }
                .disabled(workspace == nil)
            Button("Reconnect") { if let ws = workspace { Task { await ws.reconnect() } } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Disconnect") { if let id = workspace?.id { Task { await app.disconnect(id) } } }
                .disabled(workspace == nil)
            Divider()
            Button("Show Welcome") { app.showWelcome = true }
        }
    }
}

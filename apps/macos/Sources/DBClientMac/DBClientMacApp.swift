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
    }

    var body: some Scene {
        WindowGroup("DB Client") {
            RootView()
                .environment(app)
        }
        .defaultSize(width: 1320, height: 840)
        .commands { AppCommands(app: app) }
    }
}

struct AppCommands: Commands {
    let app: AppState

    private var workspace: WorkspaceModel? { app.activeWorkspace }
    private var query: QueryTabModel? { workspace?.activeQuery }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { app.newConnection() }
                .keyboardShortcut("n")
            Button("New Query Tab") { workspace?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Close Tab") {
                if let id = workspace?.selectedTabID { workspace?.closeTab(id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTabID == nil)
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
            Button("Disconnect") { if let id = workspace?.id { Task { await app.disconnect(id) } } }
                .disabled(workspace == nil)
            Divider()
            Button("Show Welcome") { app.showWelcome = true }
        }
    }
}

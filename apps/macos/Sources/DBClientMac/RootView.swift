import DBClientKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let error = app.startupError {
                ContentUnavailableView("The core could not start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let workspace = app.activeWorkspace, !app.showWelcome {
                WorkspaceView(workspace: workspace)
                    .id(workspace.id)
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(item: $app.form) { form in
            ConnectSheet(form: form)
        }
        .overlay(alignment: .top) {
            if app.showPalette {
                CommandPaletteView(commands: PaletteCommands.build(app: app)) { app.showPalette = false }
                    .padding(.top, Space.xl * 2)
            }
        }
        .alert("Could not connect", isPresented: Binding(get: { app.connectError != nil }, set: { if !$0 { app.dismissConnectError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.connectError ?? "")
        }
        .onAppear { Startup.finish() }
        .task { await DevSnapshots.run(app: app) }
    }
}

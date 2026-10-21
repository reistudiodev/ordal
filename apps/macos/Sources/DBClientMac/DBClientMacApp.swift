import AppKit
import DBClientCore
import SwiftUI

@main
struct DBClientMacApp: App {
    init() {
        // Launched with `swift run` there is no .app bundle, so tell AppKit
        // this is a regular app that gets a Dock icon and a focused window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("DB Client") {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("No connections yet")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Connections")
        } detail: {
            VStack(spacing: 8) {
                Text(greet(name: "macOS"))
                    .font(.title2)
                Text("Core v\(coreVersion())")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

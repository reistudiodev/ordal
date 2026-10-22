import DefaultBackend
import OrdalUI
import SwiftCrossUI

@main
struct OrdalPreviewApp: App {
    var body: some Scene {
        WindowGroup("Ordal") {
            OrdalRootView()
        }
    }
}

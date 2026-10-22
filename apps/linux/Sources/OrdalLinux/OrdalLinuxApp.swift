// Native Linux Desktop App using GTK 4 / GTK 3 (via GtkBackend in SwiftCrossUI).
import DefaultBackend
import OrdalUI
import SwiftCrossUI

@main
struct OrdalLinuxApp: App {
    var body: some Scene {
        WindowGroup("Ordal") {
            OrdalRootView()
        }
    }
}

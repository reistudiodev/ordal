// Native Windows Desktop App using WinUI 3 / Win32 (via WinUIBackend in SwiftCrossUI).
import DefaultBackend
import OrdalUI
import SwiftCrossUI

@main
struct OrdalWindowsApp: App {
    var body: some Scene {
        WindowGroup("Ordal") {
            OrdalRootView()
        }
    }
}

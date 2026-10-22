import Foundation
import Observation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Bridges OrdalKit's `@Observable` AppState into SwiftCrossUI's `ObservableObject`.
@MainActor
public final class AppStateContainer: SwiftCrossUI.ObservableObject {
    public let app: AppState
    public nonisolated let didChange = SwiftCrossUI.Publisher()

    public init() {
        self.app = AppState()
        startObserving()
    }

    public init(app: AppState) {
        self.app = app
        startObserving()
    }

    public func notifyUpdate() {
        didChange.send()
    }

    private func startObserving() {
        withObservationTracking {
            // Touch observed properties to register dependencies
            _ = app.activeWorkspaceID
            _ = app.connections.count
            _ = app.showWelcome
            _ = app.showInspector
            _ = app.showPalette
            _ = app.form
            if let ws = app.activeWorkspace {
                _ = ws.selectedTabID
                _ = ws.tabs.count
                _ = ws.state
                _ = ws.latencyMs
                if let q = ws.activeEditor {
                    _ = q.status
                    _ = q.isRunning
                    _ = q.pending
                    _ = q.text
                    _ = q.notice
                    _ = q.pager?.rowCount
                }
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.didChange.send()
                self.startObserving()
            }
        }
    }
}

import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Main Root Coordinator for the native cross-platform Ordal application.
public struct OrdalRootView: View {
    @State private var container = AppStateContainer()

    public init() {}

    private var app: AppState { container.app }

    public var body: some View {
        ZStack {
            // Main Content Layer
            if let workspace = app.activeWorkspace, !app.showWelcome {
                WorkspaceView(container: container, workspace: workspace)
            } else {
                WelcomeView(container: container)
            }

            // Connection Modal Form Dialog Overlay
            if let form = app.form {
                dialogBackdrop {
                    ConnectView(container: container, form: form)
                }
            }

            // Safety Destructive Query Confirmation Dialog Overlay
            if let workspace = app.activeWorkspace,
               let editor = workspace.activeEditor,
               let pending = editor.pending {
                dialogBackdrop {
                    ConfirmStatementDialog(
                        pending: pending,
                        config: workspace.config,
                        onConfirm: {
                            Task {
                                await editor.confirmPending()
                                container.notifyUpdate()
                            }
                        },
                        onCancel: {
                            editor.dismissPending()
                            container.notifyUpdate()
                        }
                    )
                }
            }

            // Command Palette Modal Overlay (Ctrl+K)
            if app.showPalette {
                dialogBackdrop {
                    CommandPaletteDialog(container: container) {
                        app.showPalette = false
                        container.notifyUpdate()
                    }
                }
            }
        }
    }

    private func dialogBackdrop<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content()
                    .background(
                        Color.adaptive(
                            light: Color(white: 1.0),
                            dark: Color(white: 0.16)
                        )
                    )
                    .cornerRadius(12)
                Spacer()
            }
            Spacer()
        }
        .background(Color(white: 0.0, opacity: 0.5))
    }
}

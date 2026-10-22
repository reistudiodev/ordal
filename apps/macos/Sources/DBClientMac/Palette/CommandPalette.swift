import DBClientKit
import SwiftUI

/// ⌘K: every action, fuzzy-searchable, keyboard only.
struct CommandPaletteView: View {
    @State private var model: PaletteModel
    @FocusState private var focused: Bool
    let dismiss: () -> Void

    init(commands: [PaletteCommand], dismiss: @escaping () -> Void) {
        _model = State(initialValue: PaletteModel(commands: commands))
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command or a table name", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(Space.m)
                .focused($focused)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onSubmit {
                    dismiss()
                    model.runSelected()
                }
                .accessibilityLabel("Command")
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let results = model.results
                        if results.isEmpty {
                            Text("No matching commands").foregroundStyle(.secondary).padding(Space.m)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, command in
                            row(command, selected: i == model.selection)
                                .id(i)
                                .onTapGesture {
                                    dismiss()
                                    command.action()
                                }
                        }
                    }
                    .padding(Space.hairline)
                }
                .frame(maxHeight: 360)
                .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { focused = true }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            Spacer()
            if let shortcut = command.shortcut {
                Text(shortcut).font(.caption.monospaced()).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, Space.s + Space.hairline)
        .padding(.vertical, Space.s - 2)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The palette's command list, rebuilt each time it opens.
@MainActor
enum PaletteCommands {
    static func build(app: AppState) -> [PaletteCommand] {
        var list: [PaletteCommand] = [
            PaletteCommand(id: "new-connection", title: "New Connection…", shortcut: "⌘N") { app.newConnection() },
            PaletteCommand(id: "welcome", title: "Show Welcome") { app.showWelcome = true },
            PaletteCommand(id: "inspector", title: app.showInspector ? "Hide Inspector" : "Show Inspector", shortcut: "⌥⌘I") {
                app.showInspector.toggle()
            },
        ]
        if let ws = app.activeWorkspace {
            list += [
                PaletteCommand(id: "new-tab", title: "New Query Tab", shortcut: "⌘T") { ws.newQueryTab() },
                PaletteCommand(id: "disconnect", title: "Disconnect", subtitle: ws.config.name) {
                    Task { await app.disconnect(ws.id) }
                },
                PaletteCommand(id: "reconnect", title: "Reconnect", subtitle: ws.config.name, shortcut: "⇧⌘R") {
                    Task { await ws.reconnect() }
                },
                PaletteCommand(id: "open-sql", title: "Open SQL File…", shortcut: "⌘O") { QueryFiles.open(in: ws) },
                PaletteCommand(id: "edit", title: "Edit Connection…", subtitle: ws.config.name) { app.edit(ws.config) },
            ]
            if let q = ws.activeEditor {
                list += [
                    PaletteCommand(id: "save", title: "Save Query", shortcut: "⌘S") { QueryFiles.save(q) },
                    PaletteCommand(id: "save-as", title: "Save Query As…", shortcut: "⇧⌘S") { QueryFiles.saveAs(q) },
                    PaletteCommand(id: "run", title: "Run Query", shortcut: "⌘↵") { Task { await q.run() } },
                    PaletteCommand(id: "cancel", title: "Cancel Query", shortcut: "⌘.") { q.cancel() },
                ]
                if ws.config.kind.isSQL {
                    list.append(PaletteCommand(id: "format", title: "Format Query", shortcut: "⇧⌘F") { q.format() })
                }
            }
            if let id = ws.selectedTabID {
                list.append(PaletteCommand(id: "close-tab", title: "Close Tab", shortcut: "⇧⌘W") { ws.closeTab(id) })
            }
            for node in ws.browser.loadedNodes {
                if let path = ws.relationsPath(for: node) {
                    list.append(PaletteCommand(id: "rel:" + node.id, title: "View Relations of \(node.name)") { ws.openSchema(path: path) })
                }
            }
            for node in ws.browser.loadedNodes where node.opensAsTable {
                list.append(PaletteCommand(id: "open:" + node.id, title: "Open \(node.name)",
                                           subtitle: node.path.dropLast().joined(separator: " › ")) { ws.openTable(node) })
            }
        }
        for c in app.connections {
            list.append(PaletteCommand(id: "connect:" + c.id, title: "Switch to \(c.name)",
                                       subtitle: "\(c.kind.label) · \(c.environment.label)") {
                Task { await app.connect(c.id) }
            })
        }
        return list
    }
}

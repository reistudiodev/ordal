import AppKit
import OrdalKit
import SwiftUI

/// The selected connection's objects, with a fuzzy filter at the top.
struct ObjectBrowser: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        @Bindable var browser = workspace.browser
        VStack(spacing: 0) {
            TextField("Filter", text: $browser.filter, prompt: Text("Filter loaded objects"))
                .textFieldStyle(.roundedBorder)
                .padding(Space.s)
                .accessibilityLabel("Filter objects")

            if let error = browser.error {
                ContentUnavailableView {
                    Label("Could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await browser.loadRoots() } }
                }
            } else if browser.isLoading && browser.roots.isEmpty {
                ProgressView().frame(maxHeight: .infinity)
            } else if !browser.filter.isEmpty {
                let matches = browser.filtered
                if matches.isEmpty {
                    ContentUnavailableView.search(text: browser.filter)
                } else {
                    List(matches) { node in
                        NodeLabel(node: node, workspace: workspace, showsPath: true)
                    }
                    .listStyle(.sidebar)
                }
            } else {
                List {
                    ForEach(browser.roots) { node in
                        NodeRow(node: node, workspace: workspace)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct NodeRow: View {
    @Bindable var node: TreeNode
    let workspace: WorkspaceModel

    var body: some View {
        if node.node.hasChildren {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("Empty").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(children) { NodeRow(node: $0, workspace: workspace) }
                } else if node.isLoading {
                    ProgressView().controlSize(.small)
                }
                if let error = node.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } label: {
                NodeLabel(node: node, workspace: workspace, showsPath: false)
            }
            .onChange(of: node.isExpanded) {
                if node.isExpanded { Task { await workspace.browser.load(node) } }
            }
        } else {
            NodeLabel(node: node, workspace: workspace, showsPath: false)
        }
    }
}

private struct NodeLabel: View {
    let node: TreeNode
    let workspace: WorkspaceModel
    let showsPath: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if showsPath, node.path.count > 1 {
                        Text(node.path.dropLast().joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: node.kind.symbol).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            if let detail = node.node.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            if node.opensAsTable {
                Button("Open") { open() }
            }
            let starter = workspace.starterQuery(for: node)
            if !starter.isEmpty {
                Button("New Query Here") {
                    workspace.newQueryTab(text: starter, database: workspace.database(for: node.path))
                }
            }
            if let path = workspace.relationsPath(for: node) {
                Button("View Relations") { workspace.openSchema(path: path) }
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.name, forType: .string)
            }
            if node.node.hasChildren {
                Button("Refresh") { Task { await workspace.browser.load(node, force: true) } }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(node.opensAsTable ? "Double-click to open" : "")
    }

    private func open() {
        if node.opensAsTable {
            workspace.openTable(node)
        } else if node.kind == .key {
            let starter = workspace.starterQuery(for: node)
            let tab = workspace.newQueryTab(text: starter, database: workspace.database(for: node.path))
            Task { await tab.run() }
        }
    }
}

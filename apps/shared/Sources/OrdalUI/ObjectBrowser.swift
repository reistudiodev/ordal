import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Native cross-platform database schema object browser (tables, views, columns, functions, collections).
public struct ObjectBrowser: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel

    public init(container: AppStateContainer, workspace: WorkspaceModel) {
        self.container = container
        self.workspace = workspace
    }

    private var browser: BrowserModel { workspace.browser }

    public var body: some View {
        VStack(spacing: 0) {
            // Filter header
            HStack(spacing: 8) {
                TextField("Filter objects...", text: Binding(get: { workspace.browser.filter }, set: { workspace.browser.filter = $0 }))
            }
            .padding(8)
            .background(Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.17)))

            // Tree list
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    if browser.isLoading && browser.roots.isEmpty {
                        Text("Loading objects...")
                            .foregroundColor(Color(white: 0.5))
                            .font(.caption)
                            .padding(12)
                    } else if let error = browser.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Failed to load:")
                                .font(.caption)
                                .foregroundColor(Color.hex(0xDC3545))
                            Text(error)
                                .font(.caption)
                                .foregroundColor(Color(white: 0.5))
                            Button("Retry") {
                                Task {
                                    await browser.loadRoots()
                                    container.notifyUpdate()
                                }
                            }
                        }
                        .padding(12)
                    } else if !browser.filter.isEmpty {
                        let filtered = browser.filtered
                        if filtered.isEmpty {
                            Text("No objects match filter")
                                .foregroundColor(Color(white: 0.5))
                                .font(.caption)
                                .padding(12)
                        } else {
                            ForEach(filtered) { node in
                                FlatNodeRow(container: container, workspace: workspace, node: node)
                            }
                        }
                    } else {
                        ForEach(browser.roots) { node in
                            TreeNodeRow(container: container, workspace: workspace, node: node, level: 0)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct TreeNodeRow: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let node: TreeNode
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Indentation
                if level > 0 {
                    Spacer()
                        .frame(width: Double(level * 14))
                }

                // Expand / Collapse arrow
                if node.node.hasChildren {
                    Button(node.isExpanded ? "▼" : "▶") {
                        node.isExpanded.toggle()
                        if node.isExpanded && node.children == nil {
                            Task {
                                await workspace.browser.load(node)
                                container.notifyUpdate()
                            }
                        } else {
                            container.notifyUpdate()
                        }
                    }
                    .frame(width: 18)
                } else {
                    Spacer()
                        .frame(width: 18)
                }

                // Node Kind Icon & Title
                Button("\(nodeIcon(node.kind)) \(node.name)") {
                    openNode()
                }

                Spacer()

                if let detail = node.node.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(Color(white: 0.4))
                }

                if node.opensAsTable || node.kind == .database || node.kind == .schema {
                    Button("📤") {
                        workspace.presentExport(for: node)
                        container.notifyUpdate()
                    }
                    .font(.caption)

                    Button("✏️") {
                        workspace.presentRename(for: node)
                        container.notifyUpdate()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            // Children when expanded
            if node.isExpanded, let children = node.children {
                if children.isEmpty {
                    HStack {
                        Spacer().frame(width: Double((level + 1) * 14 + 18))
                        Text("(empty)")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.4))
                    }
                } else {
                    ForEach(children) { child in
                        TreeNodeRow(container: container, workspace: workspace, node: child, level: level + 1)
                    }
                }
            }
        }
    }

    private func openNode() {
        if node.opensAsTable {
            workspace.openTable(node)
            container.notifyUpdate()
        } else if node.kind == .key {
            let starter = workspace.starterQuery(for: node)
            let tab = workspace.newQueryTab(text: starter, database: workspace.database(for: node.path))
            container.notifyUpdate()
            Task {
                await tab.run()
                container.notifyUpdate()
            }
        } else if node.node.hasChildren {
            node.isExpanded.toggle()
            if node.isExpanded && node.children == nil {
                Task {
                    await workspace.browser.load(node)
                    container.notifyUpdate()
                }
            } else {
                container.notifyUpdate()
            }
        }
    }

    private func nodeIcon(_ kind: NodeKind) -> String {
        switch kind {
        case .database: "🗄️"
        case .schema: "📁"
        case .folder: "📂"
        case .table: "📄"
        case .view: "👁️"
        case .function: "⚡"
        case .column: "▫️"
        case .collection: "📚"
        case .index: "🔢"
        case .keyPrefix: "📁"
        case .key: "🔑"
        }
    }
}

private struct FlatNodeRow: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let node: TreeNode

    var body: some View {
        HStack(spacing: 8) {
            Button(node.name) {
                if node.opensAsTable {
                    workspace.openTable(node)
                    container.notifyUpdate()
                }
            }
            Spacer()
            if node.path.count > 1 {
                Text(node.path.dropLast().joined(separator: " › "))
                    .font(.caption)
                    .foregroundColor(Color(white: 0.5))
            }
            if node.opensAsTable || node.kind == .database || node.kind == .schema {
                Button("📤") {
                    workspace.presentExport(for: node)
                    container.notifyUpdate()
                }
                .font(.caption)

                Button("✏️") {
                    workspace.presentRename(for: node)
                    container.notifyUpdate()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

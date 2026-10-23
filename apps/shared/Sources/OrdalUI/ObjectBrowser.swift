import Foundation
import OrdalCore
import OrdalKit
import SwiftCrossUI

/// Modern native cross-platform database schema object browser (tables, views, columns, functions, collections).
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
            // Modern Filter header
            HStack(spacing: 8) {
                ModernIcon(.search, color: Color.uiTextMuted, size: 12)
                TextField(
                    "Filter objects...",
                    text: Binding(
                        get: { workspace.browser.filter },
                        set: { workspace.browser.filter = $0 }
                    )
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.uiPanel)
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.uiSidebar)

            // Tree list
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if browser.isLoading && browser.roots.isEmpty {
                        HStack(spacing: 6) {
                            ModernIcon(.refresh, color: Color.uiTextMuted, size: 12)
                            Text("Loading database objects...")
                                .foregroundColor(Color.uiTextMuted)
                                .font(.caption)
                        }
                        .padding(12)
                    } else if let error = browser.error {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ModernIcon(.warning, color: Color.uiDanger, size: 12)
                                Text("Failed to load schema:")
                                    .font(.caption)
                                    .foregroundColor(Color.uiDanger)
                            }
                            Text(error)
                                .font(.caption)
                                .foregroundColor(Color.uiTextMuted)
                            Button("Retry") {
                                Task {
                                    await browser.loadRoots()
                                    container.notifyUpdate()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.uiHover)
                            .cornerRadius(4)
                        }
                        .padding(12)
                    } else if !browser.filter.isEmpty {
                        let filtered = browser.filtered
                        if filtered.isEmpty {
                            Text("No objects match filter")
                                .foregroundColor(Color.uiTextMuted)
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
        .background(Color.uiSidebar)
    }
}

private struct TreeNodeRow: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let node: TreeNode
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                // Indentation
                if level > 0 {
                    Spacer()
                        .frame(width: Double(level * 12))
                }

                // Expand / Collapse arrow (modern vector chevron)
                if node.node.hasChildren {
                    Button {
                        node.isExpanded.toggle()
                        if node.isExpanded && node.children == nil {
                            Task {
                                await workspace.browser.load(node)
                                container.notifyUpdate()
                            }
                        } else {
                            container.notifyUpdate()
                        }
                    } label: {
                        ModernIcon(
                            node.isExpanded ? .chevronDown : .chevronRight,
                            color: Color.uiTextMuted,
                            size: 9,
                            strokeWidth: 1.6
                        )
                        .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 14)
                } else {
                    Spacer()
                        .frame(width: 14)
                }

                // Node Vector Icon & Title Button
                Button {
                    openNode()
                } label: {
                    HStack(spacing: 6) {
                        ModernIcon(
                            iconType(for: node.kind),
                            color: iconColor(for: node.kind),
                            size: 13,
                            strokeWidth: 1.4
                        )

                        Text(node.name)
                            .font(.system(size: 13))
                            .foregroundColor(Color.uiTextPrimary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Row count or column type badge
                if let detail = node.node.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(Color.uiTextFaint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.uiHover)
                        .cornerRadius(3)
                }

                // Action buttons (modern clean vector icons without chunky borders)
                if node.opensAsTable || node.kind == .database || node.kind == .schema {
                    Button {
                        workspace.presentExport(for: node)
                        container.notifyUpdate()
                    } label: {
                        ModernIcon(.export, color: Color.uiTextMuted, size: 11, strokeWidth: 1.4)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    Button {
                        workspace.presentRename(for: node)
                        container.notifyUpdate()
                    } label: {
                        ModernIcon(.edit, color: Color.uiTextMuted, size: 11, strokeWidth: 1.4)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

            // Children when expanded
            if node.isExpanded, let children = node.children {
                if children.isEmpty {
                    HStack {
                        Spacer().frame(width: Double((level + 1) * 12 + 14))
                        Text("(empty)")
                            .font(.caption)
                            .foregroundColor(Color.uiTextFaint)
                    }
                    .padding(.vertical, 2)
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

    private func iconType(for kind: NodeKind) -> IconType {
        switch kind {
        case .database: .database
        case .schema: .schema
        case .folder: .folder
        case .table: .table
        case .view: .view
        case .function: .function
        case .column: .column
        case .collection: .table
        case .index: .index
        case .keyPrefix: .folder
        case .key: .key
        }
    }

    private func iconColor(for kind: NodeKind) -> Color {
        switch kind {
        case .database: Color.nodeDatabase
        case .schema: Color.nodeFolder
        case .folder: Color.nodeFolder
        case .table: Color.nodeTable
        case .view: Color.nodeView
        case .function: Color.nodeFunction
        case .column: Color.nodeColumn
        case .collection: Color.nodeTable
        case .index: Color.nodeIndex
        case .keyPrefix: Color.nodeFolder
        case .key: Color.nodeKey
        }
    }
}

private struct FlatNodeRow: View {
    let container: AppStateContainer
    let workspace: WorkspaceModel
    let node: TreeNode

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if node.opensAsTable {
                    workspace.openTable(node)
                    container.notifyUpdate()
                }
            } label: {
                HStack(spacing: 6) {
                    ModernIcon(iconType(for: node.kind), color: iconColor(for: node.kind), size: 13)
                    Text(node.name)
                        .font(.system(size: 13))
                        .foregroundColor(Color.uiTextPrimary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if node.path.count > 1 {
                Text(node.path.dropLast().joined(separator: " › "))
                    .font(.caption)
                    .foregroundColor(Color.uiTextMuted)
            }

            if node.opensAsTable || node.kind == .database || node.kind == .schema {
                Button {
                    workspace.presentExport(for: node)
                    container.notifyUpdate()
                } label: {
                    ModernIcon(.export, color: Color.uiTextMuted, size: 11)
                }
                .buttonStyle(.plain)

                Button {
                    workspace.presentRename(for: node)
                    container.notifyUpdate()
                } label: {
                    ModernIcon(.edit, color: Color.uiTextMuted, size: 11)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func iconType(for kind: NodeKind) -> IconType {
        switch kind {
        case .database: .database
        case .schema: .schema
        case .folder: .folder
        case .table: .table
        case .view: .view
        case .function: .function
        case .column: .column
        case .collection: .table
        case .index: .index
        case .keyPrefix: .folder
        case .key: .key
        }
    }

    private func iconColor(for kind: NodeKind) -> Color {
        switch kind {
        case .database: Color.nodeDatabase
        case .schema: Color.nodeFolder
        case .folder: Color.nodeFolder
        case .table: Color.nodeTable
        case .view: Color.nodeView
        case .function: Color.nodeFunction
        case .column: Color.nodeColumn
        case .collection: Color.nodeTable
        case .index: Color.nodeIndex
        case .keyPrefix: Color.nodeFolder
        case .key: Color.nodeKey
        }
    }
}

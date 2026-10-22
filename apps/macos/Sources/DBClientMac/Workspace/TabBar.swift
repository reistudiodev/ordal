import DBClientKit
import SwiftUI

struct TabBar: View {
    let workspace: WorkspaceModel
    @State private var hovered: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        chip(tab)
                    }
                }
                .padding(.horizontal, Space.s)
            }
            Button {
                workspace.newQueryTab()
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New query tab (⌘T)")
            .accessibilityLabel("New query tab")
            .padding(.trailing, Space.s)
        }
        .frame(height: 36)
    }

    private func chip(_ tab: WorkspaceModel.Tab) -> some View {
        let selected = tab.id == workspace.selectedTabID
        return HStack(spacing: Space.hairline) {
            Image(systemName: icon(tab)).font(.caption).foregroundStyle(.secondary)
            Text(tab.title).lineLimit(1)
            Button {
                workspace.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .opacity(selected || hovered == tab.id ? 1 : 0)
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.hairline + 2)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if selected, workspace.config.environment.showsChrome {
                Rectangle().fill(workspace.config.accent).frame(height: 2).padding(.horizontal, Space.s)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedTabID = tab.id }
        .onHover { hovered = $0 ? tab.id : nil }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func icon(_ tab: WorkspaceModel.Tab) -> String {
        switch tab {
        case .query: "text.cursor"
        case .table(let t): t.kind.symbol
        case .schema: "point.3.connected.trianglepath.dotted"
        }
    }
}

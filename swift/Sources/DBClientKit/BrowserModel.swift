import Foundation
import Observation

/// One node in the object browser. Children load on first expand.
@MainActor @Observable
public final class TreeNode: Identifiable {
    public let node: BrowseNode
    public let path: [String]
    public private(set) var children: [TreeNode]?
    public private(set) var isLoading = false
    public private(set) var error: String?
    public var isExpanded = false

    public nonisolated var id: String { path.joined(separator: "\u{1F}") }
    public var name: String { node.name }
    public var kind: NodeKind { node.kind }

    init(node: BrowseNode, path: [String]) {
        self.node = node
        self.path = path
    }

    /// Tables, views and collections open in a data tab.
    public var opensAsTable: Bool {
        switch node.kind {
        case .table, .view, .collection: true
        default: false
        }
    }

    fileprivate func setChildren(_ nodes: [BrowseNode]) {
        children = nodes.map { TreeNode(node: $0, path: path + [$0.name]) }
    }

    fileprivate func setLoading(_ loading: Bool) { isLoading = loading }
    fileprivate func setError(_ message: String?) { error = message }
}

@MainActor @Observable
public final class BrowserModel {
    public private(set) var roots: [TreeNode] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    public var filter = ""

    private var session: Session

    public init(session: Session) {
        self.session = session
    }

    func rebind(_ session: Session) {
        self.session = session
    }

    public func loadRoots() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let nodes = try await session.listChildren(path: [])
            roots = nodes.map { TreeNode(node: $0, path: [$0.name]) }
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    /// Loads `node`'s children if needed (call when it is expanded).
    public func load(_ node: TreeNode, force: Bool = false) async {
        guard node.node.hasChildren, force || node.children == nil, !node.isLoading else { return }
        node.setLoading(true)
        defer { node.setLoading(false) }
        do {
            node.setChildren(try await session.listChildren(path: node.path))
            node.setError(nil)
        } catch {
            node.setError(describe(error))
        }
    }

    public func expand(_ node: TreeNode) async {
        node.isExpanded = true
        await load(node)
    }

    /// Every node loaded so far, depth first.
    public var loadedNodes: [TreeNode] {
        var out: [TreeNode] = []
        func walk(_ nodes: [TreeNode]) {
            for n in nodes {
                out.append(n)
                if let c = n.children { walk(c) }
            }
        }
        walk(roots)
        return out
    }

    /// Loaded nodes matching `filter`, best first. Folders are skipped.
    public var filtered: [TreeNode] {
        Fuzzy.filter(loadedNodes.filter { $0.kind != .folder }, query: filter, key: \.name)
    }

    /// The node at `path`, if loaded.
    public func node(at path: [String]) -> TreeNode? {
        loadedNodes.first { $0.path == path }
    }
}

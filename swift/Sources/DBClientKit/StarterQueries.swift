import Foundation

extension WorkspaceModel {
    /// A first query for a browser node, in the engine's own language.
    public func starterQuery(for node: TreeNode) -> String {
        starterQuery(path: node.path, kind: node.kind, detail: node.node.detail)
    }

    public func starterQuery(path p: [String], kind: NodeKind, detail: String?) -> String {
        let opensAsTable = [.table, .view, .collection].contains(kind)
        switch config.kind {
        case .postgres where p.count == 4 && opensAsTable:
            return "SELECT *\nFROM \(Self.quote(p[1], "\"")).\(Self.quote(p[3], "\""))\nLIMIT 100;"
        case .mySql where p.count == 3 && opensAsTable:
            return "SELECT *\nFROM \(Self.quote(p[0], "`")).\(Self.quote(p[2], "`"))\nLIMIT 100;"
        case .sqlite where p.count == 3 && opensAsTable:
            return "SELECT *\nFROM \(Self.quote(p[2], "\""))\nLIMIT 100;"
        case .mongoDb where p.count == 2:
            return "{\"find\": \(Self.jsonString(p[1])), \"filter\": {}, \"limit\": 100}"
        case .redis where kind == .key:
            let key = Self.redisArg(p.dropFirst().joined(separator: ":"))
            switch detail {
            case "hash": return "HGETALL \(key)"
            case "list": return "LRANGE \(key) 0 99"
            case "set": return "SMEMBERS \(key)"
            case "zset": return "ZRANGE \(key) 0 99 WITHSCORES"
            case "stream": return "XRANGE \(key) - + COUNT 100"
            case "string": return "GET \(key)"
            default: return "TYPE \(key)"
            }
        default:
            return ""
        }
    }

    static func quote(_ name: String, _ q: String) -> String {
        q + name.replacingOccurrences(of: q, with: q + q) + q
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data()
        return String(data: data, encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "\"\(s)\""
    }

    static func redisArg(_ s: String) -> String {
        s.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            : s
    }
}

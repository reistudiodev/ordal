import Foundation

/// A small, safe SQL formatter: upper-cases keywords and starts major
/// clauses on new lines. It never touches string literals, quoted
/// identifiers or comments.
public enum SQLFormatter {
    static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "is", "null", "as", "on", "join", "left", "right",
        "inner", "outer", "full", "cross", "group", "by", "order", "having", "limit", "offset", "union", "all",
        "distinct", "insert", "into", "values", "update", "set", "delete", "create", "table", "view", "index",
        "alter", "drop", "with", "case", "when", "then", "else", "end", "asc", "desc", "returning", "like",
        "between", "exists", "default", "primary", "key", "references", "truncate", "explain", "analyze",
    ]
    static let breakBefore: Set<String> = [
        "from", "where", "group", "order", "having", "limit", "offset", "union", "values", "set", "returning",
        "join", "left", "right", "inner", "full", "cross",
    ]
    /// Words that continue the previous clause keyword (`LEFT JOIN`, `GROUP BY`).
    static let joiners: Set<String> = ["join", "by", "outer", "all"]

    public static func format(_ sql: String) -> String {
        var out = ""
        var i = sql.startIndex
        var previousWord = ""
        var depth = 0
        func emitSpace() {
            if let last = out.last, !last.isWhitespace, last != "(", last != ".", !out.hasSuffix("::") { out.append(" ") }
        }
        func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" }
        while i < sql.endIndex {
            let c = sql[i]
            let next = sql.index(after: i)
            if c == "'" || c == "\"" || c == "`" {
                let end = closing(of: c, in: sql, from: i)
                emitSpace()
                out += sql[i..<end]
                i = end
            } else if c == "-", next < sql.endIndex, sql[next] == "-" {
                let end = sql[i...].firstIndex(of: "\n") ?? sql.endIndex
                emitSpace()
                out += sql[i..<end] + "\n"
                i = end < sql.endIndex ? sql.index(after: end) : end
            } else if isWordChar(c) {
                var j = i
                while j < sql.endIndex, isWordChar(sql[j]) { j = sql.index(after: j) }
                let word = String(sql[i..<j])
                let lower = word.lowercased()
                if depth == 0, breakBefore.contains(lower), !(joiners.contains(lower) && breakBefore.contains(previousWord)),
                   !out.isEmpty, !out.hasSuffix(".") {
                    while out.last == " " { out.removeLast() }
                    out += "\n"
                } else {
                    emitSpace()
                }
                out += keywords.contains(lower) ? word.uppercased() : word
                previousWord = lower
                i = j
            } else if c.isWhitespace {
                i = next
            } else if "(),;".contains(c) {
                if c == "(" {
                    depth += 1
                    // `count(` and `IN (` read better than `count (` and `IN(`.
                    if keywords.contains(previousWord) { emitSpace() }
                } else {
                    if c == ")" { depth = max(0, depth - 1) }
                    while out.last == " " { out.removeLast() }
                }
                out.append(c)
                if c == ";" { out += "\n\n"; previousWord = "" }
                i = next
            } else {
                // An operator run such as `>=`, `||`, `::` or `.`.
                var j = i
                while j < sql.endIndex, !isWordChar(sql[j]), !sql[j].isWhitespace, !"(),;'\"`".contains(sql[j]) {
                    j = sql.index(after: j)
                }
                let op = String(sql[i..<j])
                if op == "." || op == "::" || op == ".*" {
                    while out.last == " " { out.removeLast() }
                } else {
                    emitSpace()
                }
                out += op
                if op == ".*" { previousWord = "" }
                i = j
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func closing(of q: Character, in s: String, from start: String.Index) -> String.Index {
        var i = s.index(after: start)
        while i < s.endIndex {
            if s[i] == q {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == q { i = s.index(after: next); continue }
                return next
            }
            i = s.index(after: i)
        }
        return s.endIndex
    }
}

/// Subsequence fuzzy matching for the object browser filter and the command palette.
public enum Fuzzy {
    /// A score for `query` inside `candidate`, or nil when the characters
    /// don't all appear in order. Higher is better: consecutive matches,
    /// matches at word starts and an exact prefix score extra.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var score = 0
        var qi = 0
        var previous = -2
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if ci == previous + 1 { score += 5 }
            if ci == 0 || !c[ci - 1].isLetter && !c[ci - 1].isNumber { score += 3 }
            previous = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if c.starts(with: q) { score += 10 }
        return score - c.count / 8
    }

    /// `items` that match, best first; ties keep their original order.
    public static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in score(query, in: key(item)).map { (item, $0, i) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }
}

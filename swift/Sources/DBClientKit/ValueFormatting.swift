import Foundation

extension Value {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// One-line text for a grid cell. Long text and JSON are truncated.
    public var cellText: String {
        switch self {
        case .null: "NULL"
        case .bool(let v): v ? "true" : "false"
        case .int(let v): String(v)
        // Locale-independent shortest round-trip form: data is not prose.
        case .float(let v): String(v)
        case .decimal(let v), .date(let v), .time(let v), .uuid(let v): v
        case .timestamp(let v, _): v
        case .text(let v): Self.oneLine(v)
        case .json(let v): Self.oneLine(v)
        case .bytes(let v): Self.hexPreview(v)
        }
    }

    /// Full text for the inspector: JSON pretty-printed, bytes as hex.
    public var inspectorText: String {
        switch self {
        case .text(let v): v
        case .json(let v): Self.prettyJSON(v) ?? v
        case .bytes(let v): v.map { String(format: "%02x", $0) }.joined(separator: " ")
        default: cellText
        }
    }

    private static func oneLine(_ s: String, limit: Int = 300) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎ ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func hexPreview(_ b: Data) -> String {
        let shown = b.prefix(32).map { String(format: "%02x", $0) }.joined()
        return "0x" + shown + (b.count > 32 ? "… (\(b.count) bytes)" : "")
    }

    static func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }
}

extension ValueKind {
    /// Numbers are right-aligned in grids.
    public var isNumeric: Bool {
        switch self {
        case .int, .float, .decimal: true
        default: false
        }
    }
}

extension CoreError {
    /// The text to show a user.
    public var message: String {
        switch self {
        case .Cancelled: "Query cancelled."
        case .NotImplemented(let m), .InvalidConfig(let m), .Connection(let m), .Auth(let m), .Timeout(let m),
             .Secret(let m), .Unsupported(let m), .NotFound(let m), .ReadOnly(let m), .Internal(let m):
            Self.prefix(for: self) + m
        case .Query(let m, _): m
        }
    }

    private static func prefix(for e: CoreError) -> String {
        switch e {
        case .Connection: "Could not connect: "
        case .Auth: "Authentication failed: "
        case .Timeout: "Timed out: "
        case .InvalidConfig: "Invalid settings: "
        case .Secret: "Keychain: "
        default: ""
        }
    }
}

/// Any error as user text.
public func describe(_ error: Error) -> String {
    (error as? CoreError)?.message ?? error.localizedDescription
}

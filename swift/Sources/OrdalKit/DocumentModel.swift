import Foundation

/// A MongoDB document for display, parsed from Extended JSON with the stored
/// field order kept (`JSONSerialization` would lose it).
public indirect enum DocValue: Equatable, Sendable {
    case object([Field])
    case array([DocValue])
    case string(String)
    /// The number exactly as written, so big integers and decimals keep their digits.
    case number(String)
    case bool(Bool)
    case null
    case int32(String)
    case double(String)
    case objectId(String)
    case date(String)
    case decimal(String)
    case long(String)
    case binary(base64: String, subtype: String)
    /// Any other `$`-type (regex, timestamp…), shown as its JSON.
    case other(String)

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: DocValue
    }

    /// Parses relaxed or canonical Extended JSON. Returns nil for invalid JSON.
    public static func parse(_ json: String) -> DocValue? {
        var p = Parser(Array(json.utf8))
        guard let v = p.value() else { return nil }
        p.skipSpace()
        return p.atEnd ? v.typed : nil
    }

    /// Field count for objects, element count for arrays.
    public var count: Int? {
        switch self {
        case .object(let f): f.count
        case .array(let a): a.count
        default: nil
        }
    }

    public var isContainer: Bool { count != nil }

    /// A short type name, like Compass shows next to values.
    public var typeName: String {
        switch self {
        case .object: "Object"
        case .array: "Array"
        case .string: "String"
        // Plain JSON numbers (relaxed form): guess from the digits.
        case .number(let n): n.contains(".") || n.contains("e") || n.contains("E") ? "Double" : Int32(n) != nil ? "Int32" : "Int64"
        case .int32: "Int32"
        case .double: "Double"
        case .bool: "Boolean"
        case .null: "Null"
        case .objectId: "ObjectId"
        case .date: "Date"
        case .decimal: "Decimal128"
        case .long: "Int64"
        case .binary: "Binary"
        case .other: "Other"
        }
    }

    /// One-line text for a value (containers summarise their size).
    public var preview: String {
        switch self {
        case .object(let f): f.isEmpty ? "{}" : "Object (\(f.count) \(f.count == 1 ? "field" : "fields"))"
        case .array(let a): "Array (\(a.count))"
        case .string(let s): "\"\(s)\""
        case .number(let n), .long(let n), .int32(let n), .double(let n): n
        case .decimal(let d): d
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .objectId(let id): "ObjectId('\(id)')"
        case .date(let d): d
        case .binary(let b64, let st): "Binary('\(b64.prefix(24))\(b64.count > 24 ? "…" : "")', \(st))"
        case .other(let j): j
        }
    }

    /// Recognises Extended JSON wrappers (`{"$oid": …}`, `{"$date": …}`…).
    var typed: DocValue {
        switch self {
        case .array(let a):
            return .array(a.map(\.typed))
        case .object(let fields):
            if fields.count == 1, let f = fields.first {
                switch (f.key, f.value) {
                case ("$oid", .string(let s)): return .objectId(s)
                case ("$numberDecimal", .string(let s)): return .decimal(s)
                case ("$numberLong", .string(let s)): return .long(s)
                case ("$numberInt", .string(let s)): return .int32(s)
                case ("$numberDouble", .string(let s)): return .double(s)
                case ("$date", .string(let s)): return .date(s)
                case ("$date", .object(let inner)):
                    if case .string(let ms)? = inner.first(where: { $0.key == "$numberLong" })?.value,
                       let millis = Double(ms) {
                        return .date(Self.iso(millis))
                    }
                case ("$date", .number(let n)):
                    if let millis = Double(n) { return .date(Self.iso(millis)) }
                case ("$binary", .object(let inner)):
                    if case .string(let b64)? = inner.first(where: { $0.key == "base64" })?.value,
                       case .string(let st)? = inner.first(where: { $0.key == "subType" })?.value {
                        return .binary(base64: b64, subtype: st)
                    }
                default:
                    break
                }
                if f.key.hasPrefix("$") { return .other(Self.render(self)) }
            }
            return .object(fields.map { Field(key: $0.key, value: $0.value.typed) })
        default:
            return self
        }
    }

    private static func iso(_ millis: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    /// Pretty JSON in stored field order, typed values in shell form
    /// (`ObjectId('…')`, `ISODate('…')`), like Compass's JSON view.
    public func prettyText(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let body = fields.map { "\(inner)\(Self.quote($0.key)): \($0.value.prettyText(indent: indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { "\(inner)\($0.prettyText(indent: indent + 1))" }
            return "[\n" + body.joined(separator: ",\n") + "\n\(pad)]"
        case .string(let s): return Self.quote(s)
        case .date(let d): return "ISODate('\(d)')"
        case .decimal(let d): return "NumberDecimal('\(d)')"
        case .long(let l): return "NumberLong('\(l)')"
        default: return preview
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    private static func render(_ v: DocValue) -> String {
        switch v {
        case .object(let f): "{" + f.map { "\(quote($0.key)): \(render($0.value))" }.joined(separator: ", ") + "}"
        case .array(let a): "[" + a.map(render).joined(separator: ", ") + "]"
        case .string(let s): quote(s)
        default: v.preview
        }
    }

    // MARK: Parser

    private struct Parser {
        let b: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { b = bytes }

        var atEnd: Bool { i >= b.count }

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        mutating func value() -> DocValue? {
            skipSpace()
            guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map(DocValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ v: DocValue) -> DocValue? {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func number() -> DocValue? {
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            guard i > start, let s = String(bytes: b[start..<i], encoding: .utf8), Double(s) != nil else { return nil }
            return .number(s)
        }

        mutating func string() -> String? {
            i += 1
            var bytes: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: bytes, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { return nil }
                    switch b[i] {
                    case UInt8(ascii: "n"): bytes.append(0x0A)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "r"): bytes.append(0x0D)
                    case UInt8(ascii: "b"): bytes.append(0x08)
                    case UInt8(ascii: "f"): bytes.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard let scalar = unicode() else { return nil }
                        bytes.append(contentsOf: Array(String(scalar).utf8))
                        continue
                    default: bytes.append(b[i])
                    }
                    i += 1
                    continue
                }
                bytes.append(c)
                i += 1
            }
            return nil
        }

        /// `\uXXXX`, including surrogate pairs. `i` points at the `u`.
        mutating func unicode() -> Character? {
            func hex4(_ at: Int) -> UInt32? {
                guard at + 4 <= b.count, let s = String(bytes: b[at..<at + 4], encoding: .utf8) else { return nil }
                return UInt32(s, radix: 16)
            }
            guard let hi = hex4(i + 1) else { return nil }
            i += 5
            if (0xD800...0xDBFF).contains(hi), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u"),
               let lo = hex4(i + 2), (0xDC00...0xDFFF).contains(lo) {
                i += 6
                return Unicode.Scalar(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)).map(Character.init)
            }
            return Unicode.Scalar(hi).map(Character.init) ?? "\u{FFFD}"
        }

        mutating func object() -> DocValue? {
            i += 1
            var fields: [Field] = []
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
            while true {
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                fields.append(Field(key: key, value: v))
                skipSpace()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                return nil
            }
        }

        mutating func array() -> DocValue? {
            i += 1
            var items: [DocValue] = []
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                skipSpace()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        }
    }
}

/// How MongoDB results are shown. Documents is the default, like Compass.
public enum DocumentViewMode: String, CaseIterable, Identifiable, Sendable {
    case documents = "Documents"
    case table = "Table"
    case json = "JSON"
    public var id: String { rawValue }
}

extension CursorPager {
    /// The whole document behind a row, for MongoDB query results (whose
    /// single column is the document).
    public func document(at index: Int) -> String? {
        guard columns.count == 1, columns[0].kind == .json, let row = row(at: index), case .json(let v) = row.cells.first else { return nil }
        return v
    }

    public var hasDocuments: Bool { columns.count == 1 && columns[0].name == "document" && columns[0].kind == .json }
}

extension TablePager {
    /// The whole document behind a row of the current page (document stores).
    public func document(at index: Int) -> String? {
        guard let docs = page?.documents, index < docs.count else { return nil }
        return docs[index]
    }

    public var hasDocuments: Bool { !(page?.documents.isEmpty ?? true) }

    /// The column index of a top-level field, for editing it from a document card.
    public func columnIndex(of field: String) -> Int? {
        page?.columns.firstIndex { $0.name == field }
    }
}

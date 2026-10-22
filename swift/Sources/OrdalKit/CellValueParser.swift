import Foundation

/// Turns what a user typed into a typed value for a column, or explains why
/// it doesn't fit: integer ranges per SQL type, decimal precision and scale,
/// date and time formats, UUIDs, JSON, enum members and text length.
public enum CellValueParser {
    public static func parse(_ input: String, for column: ColumnMeta) -> Result<Value, ParseError> {
        let text = column.kind == .text || column.kind == .other ? input : input.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = column.typeName.lowercased()

        if !column.enumValues.isEmpty {
            return column.enumValues.contains(text) ? .success(.text(v: text)) : .failure(.init("Choose one of: \(column.enumValues.joined(separator: ", "))"))
        }
        switch column.kind {
        case .bool:
            switch text.lowercased() {
            case "true", "t", "1", "yes": return .success(.bool(v: true))
            case "false", "f", "0", "no": return .success(.bool(v: false))
            default: return .failure(.init("Enter true or false"))
            }
        case .int:
            guard let v = Int64(text) else {
                if type.contains("unsigned"), UInt64(text) != nil { return .success(.decimal(v: text)) }
                return .failure(.init(text.isEmpty ? "Enter a whole number, or set NULL" : "Not a whole number"))
            }
            if let (lo, hi) = intRange(type), v < lo || v > hi {
                return .failure(.init("Must be between \(lo) and \(hi) for \(column.typeName)"))
            }
            return .success(.int(v: v))
        case .float:
            guard let v = Double(text), v.isFinite else { return .failure(.init("Not a number")) }
            return .success(.float(v: v))
        case .decimal:
            guard text.range(of: #"^-?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil else {
                return .failure(.init("Not a number"))
            }
            if let (precision, scale) = precisionScale(type) {
                let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
                let whole = String(parts[0]).drop { $0 == "0" }.count
                let frac = parts.count > 1 ? parts[1].count : 0
                if frac > scale { return .failure(.init("At most \(scale) digits after the point")) }
                if whole > precision - scale { return .failure(.init("Too large for \(column.typeName)")) }
            }
            return .success(.decimal(v: text))
        case .date:
            return matches(text, #"^\d{4}-\d{2}-\d{2}$"#) && validDate(String(text.prefix(10)))
                ? .success(.date(v: text)) : .failure(.init("Use YYYY-MM-DD"))
        case .time:
            return matches(text, #"^\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?([+-]\d{2}(:?\d{2})?)?$"#)
                ? .success(.time(v: text)) : .failure(.init("Use HH:MM:SS"))
        case .timestamp, .timestampTz:
            let zone = column.kind == .timestampTz
            let pattern = #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?"# + (zone ? #"(Z|[+-]\d{2}(:?\d{2})?)?$"# : "$")
            guard matches(text, pattern), validDate(String(text.prefix(10))) else {
                return .failure(.init(zone ? "Use YYYY-MM-DD HH:MM:SS, optionally with a zone like +07:00" : "Use YYYY-MM-DD HH:MM:SS"))
            }
            return .success(.timestamp(v: text, hasTz: zone))
        case .uuid:
            return UUID(uuidString: text) != nil ? .success(.uuid(v: text.lowercased())) : .failure(.init("Not a UUID"))
        case .json:
            guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                return .failure(.init("Not valid JSON"))
            }
            return .success(.json(v: text))
        case .bytes:
            return .failure(.init("Binary values can't be edited here"))
        case .text, .other:
            if type == "objectid" {
                return matches(text, #"^[0-9a-fA-F]{24}$"#) ? .success(.text(v: text.lowercased())) : .failure(.init("An ObjectId is 24 hex characters"))
            }
            if type == "mixed" || type == "object" || type == "array" {
                // A MongoDB field of several types: accept JSON, else text.
                if let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                    return .success(.json(v: text))
                }
                return .success(.text(v: text))
            }
            if let limit = lengthLimit(type), text.count > limit {
                return .failure(.init("At most \(limit) characters (\(text.count) now)"))
            }
            return .success(.text(v: text))
        }
    }

    public struct ParseError: Error, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// What the editor shows for an existing value (no truncation, no "NULL").
    public static func editText(_ value: Value) -> String {
        switch value {
        case .null: ""
        case .json(let v): Value.prettyJSON(v) ?? v
        default: value.inspectorText
        }
    }

    // MARK: Type details

    static func intRange(_ type: String) -> (Int64, Int64)? {
        let unsigned = type.contains("unsigned")
        let base = type.split(separator: " ").first.map(String.init) ?? type
        let name = base.split(separator: "(").first.map(String.init) ?? base
        switch name {
        case "tinyint": return unsigned ? (0, 255) : (-128, 127)
        case "smallint", "int2", "smallserial": return unsigned ? (0, 65_535) : (-32_768, 32_767)
        case "mediumint": return unsigned ? (0, 16_777_215) : (-8_388_608, 8_388_607)
        case "int", "integer", "int4", "serial": return unsigned ? (0, 4_294_967_295) : (Int64(Int32.min), Int64(Int32.max))
        case "bigint", "int8", "bigserial": return unsigned ? (0, Int64.max) : nil
        case "int32": return (Int64(Int32.min), Int64(Int32.max))
        default: return nil
        }
    }

    /// `numeric(10,2)` / `decimal(10,2)` → (10, 2).
    static func precisionScale(_ type: String) -> (Int, Int)? {
        guard let open = type.firstIndex(of: "("), let close = type.firstIndex(of: ")"), open < close else { return nil }
        let parts = type[type.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let p = parts.first else { return nil }
        return (p, parts.count > 1 ? parts[1] : 0)
    }

    /// `character varying(20)`, `varchar(20)`, `char(3)`, `character(3)` → the limit.
    static func lengthLimit(_ type: String) -> Int? {
        guard type.hasPrefix("char") || type.hasPrefix("varchar") || type.hasPrefix("character") || type.hasPrefix("nvarchar"),
              let open = type.firstIndex(of: "("), let close = type.firstIndex(of: ")") else { return nil }
        return Int(type[type.index(after: open)..<close])
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func validDate(_ ymd: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: ymd) != nil
    }
}

//! One value type for every engine. The grid, inspector and exporters only
//! ever see these types, never driver-specific ones.

/// A single cell. Dates and times are ISO-8601 text so the FFI stays simple.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Value {
    Null,
    Bool { v: bool },
    Int { v: i64 },
    Float { v: f64 },
    /// Exact numerics (NUMERIC, DECIMAL) and integers too large for i64.
    Decimal { v: String },
    Text { v: String },
    Bytes { v: Vec<u8> },
    Date { v: String },
    Time { v: String },
    Timestamp { v: String, has_tz: bool },
    Uuid { v: String },
    /// JSON text: JSON/JSONB columns, Mongo documents, nested Redis replies.
    Json { v: String },
}

/// The kind of a column, used by the UI for colours and alignment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ValueKind {
    Bool,
    Int,
    Float,
    Decimal,
    Text,
    Bytes,
    Date,
    Time,
    Timestamp,
    TimestampTz,
    Uuid,
    Json,
    Other,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ColumnInfo {
    pub name: String,
    /// The engine's own type name, e.g. `INT4`, `VARCHAR`, `hash`.
    pub type_name: String,
    pub kind: ValueKind,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Row {
    pub cells: Vec<Value>,
}

/// A page of rows pulled from a running query.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Page {
    pub rows: Vec<Row>,
    /// No more rows will come after this page.
    pub done: bool,
}

/// A random-access slice of a table or collection, for table tabs.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Window {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RowCount {
    pub count: u64,
    /// False when the engine only gave an estimate.
    pub exact: bool,
}

impl Value {
    pub(crate) fn text(s: impl Into<String>) -> Self {
        Self::Text { v: s.into() }
    }

    /// Builds a value from the textual form an engine sent, using the column kind.
    /// Falls back to text when the string does not parse as the expected kind.
    pub(crate) fn from_text(kind: ValueKind, s: &str) -> Self {
        let parsed = match kind {
            ValueKind::Bool => match s {
                "t" | "true" | "1" | "TRUE" => Some(Self::Bool { v: true }),
                "f" | "false" | "0" | "FALSE" => Some(Self::Bool { v: false }),
                _ => None,
            },
            ValueKind::Int => match s.parse::<i64>() {
                Ok(v) => Some(Self::Int { v }),
                // u64 / NUMERIC-sized integers.
                Err(_) => Some(Self::Decimal { v: s.to_string() }),
            },
            ValueKind::Float => s.parse::<f64>().ok().map(|v| Self::Float { v }),
            ValueKind::Decimal => Some(Self::Decimal { v: s.to_string() }),
            ValueKind::Date => Some(Self::Date { v: s.to_string() }),
            ValueKind::Time => Some(Self::Time { v: s.to_string() }),
            ValueKind::Timestamp => Some(Self::Timestamp { v: s.to_string(), has_tz: false }),
            ValueKind::TimestampTz => Some(Self::Timestamp { v: s.to_string(), has_tz: true }),
            ValueKind::Uuid => Some(Self::Uuid { v: s.to_string() }),
            ValueKind::Json => Some(Self::Json { v: s.to_string() }),
            ValueKind::Bytes | ValueKind::Text | ValueKind::Other => None,
        };
        parsed.unwrap_or_else(|| Self::text(s))
    }
}

/// Postgres `\x0a0b` text form of bytea.
pub(crate) fn decode_pg_hex(s: &str) -> Option<Vec<u8>> {
    let hex = s.strip_prefix("\\x")?;
    if hex.len() % 2 != 0 {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_by_kind() {
        assert_eq!(Value::from_text(ValueKind::Int, "42"), Value::Int { v: 42 });
        assert_eq!(
            Value::from_text(ValueKind::Int, "18446744073709551615"),
            Value::Decimal { v: "18446744073709551615".into() }
        );
        assert_eq!(Value::from_text(ValueKind::Bool, "t"), Value::Bool { v: true });
        assert_eq!(Value::from_text(ValueKind::Float, "1.5"), Value::Float { v: 1.5 });
        assert_eq!(Value::from_text(ValueKind::Float, "nope"), Value::text("nope"));
    }

    #[test]
    fn timestamps_carry_zone_from_kind() {
        assert_eq!(
            Value::from_text(ValueKind::TimestampTz, "2024-01-02 03:04:05-05"),
            Value::Timestamp { v: "2024-01-02 03:04:05-05".into(), has_tz: true }
        );
    }

    #[test]
    fn pg_hex() {
        assert_eq!(decode_pg_hex("\\x0aff"), Some(vec![0x0a, 0xff]));
        assert_eq!(decode_pg_hex("0aff"), None);
    }
}

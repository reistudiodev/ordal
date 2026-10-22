//! Table tabs: pages, table metadata, cell edits and the relations graph.
//!
//! Pages use keyset pagination (`WHERE key > last ORDER BY key LIMIT n`)
//! wherever a stable key exists, so page 1,000,000 of a 100M-row table costs
//! the same as page 1. OFFSET is only used for relations without any key
//! (views, MySQL tables without a primary key) or for an explicit jump.

use crate::value::{ColumnInfo, Row, Value, ValueKind};

/// Where a page starts.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PageCursor {
    First,
    Last,
    /// Rows after this paging key (the previous page's `last_key`).
    After { key: Vec<Value> },
    /// Rows before this paging key (the next page's `first_key`).
    Before { key: Vec<Value> },
    /// An explicit jump. Cost grows with the offset on every engine.
    Offset { offset: u64 },
}

/// A server-side sort chosen from a column header.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SortSpec {
    pub column: String,
    pub descending: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TablePage {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Row>,
    /// The edit key of each row, in row order. Empty when rows can't be edited.
    pub row_keys: Vec<Vec<Value>>,
    /// Paging keys for `PageCursor::Before` / `After` (the sort value first
    /// when sorted, then the key). None in OFFSET mode.
    pub first_key: Option<Vec<Value>>,
    pub last_key: Option<Vec<Value>>,
    pub has_prev: bool,
    pub has_next: bool,
    /// Offset of the first row, when known (first page, OFFSET jumps).
    pub offset: Option<u64>,
    /// Document stores: each row's whole document as Extended JSON, with the
    /// stored field order. Empty for SQL tables.
    pub documents: Vec<String>,
}

/// How a table's pages are addressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PagingMode {
    /// Keyset on the primary key (or `_id`, `rowid`, `ctid`).
    Keyset,
    /// No usable key: OFFSET only. Deep pages get slow on big tables.
    Offset,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ColumnMeta {
    pub name: String,
    /// The full declared type, e.g. `character varying(20)`, `int unsigned`.
    pub type_name: String,
    pub kind: ValueKind,
    pub nullable: bool,
    pub is_key: bool,
    pub has_default: bool,
    /// Allowed values for enum / set columns.
    pub enum_values: Vec<String>,
    /// False for generated, identity-always and key columns.
    pub editable: bool,
    /// Leads an index, so sorting by it stays fast on big tables.
    pub indexed: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TableMeta {
    pub columns: Vec<ColumnMeta>,
    pub paging: PagingMode,
    /// The columns that identify a row for edits (`_id` for MongoDB).
    pub key_columns: Vec<String>,
    /// Whether cells can be edited at all.
    pub editable: bool,
    /// Why editing is off, for the UI.
    pub read_only_reason: Option<String>,
}

/// One staged change: set `column` of the row identified by `key` to `value`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CellEdit {
    pub key: Vec<Value>,
    pub column: String,
    pub value: Value,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GraphColumn {
    pub name: String,
    /// Short type name, e.g. `int4`, `timestamptz`, `varchar(20)`, `objectId`.
    pub type_name: String,
    pub is_key: bool,
    /// Values come from the database: identity, serial, auto_increment, rowid alias.
    pub is_identity: bool,
    /// A single-column unique constraint or index (primary keys excluded).
    pub is_unique: bool,
    pub nullable: bool,
}

impl GraphColumn {
    /// A column known only from a foreign key on a table outside the graph.
    pub(crate) fn stub(name: String, is_key: bool) -> Self {
        Self { name, type_name: String::new(), is_key, is_identity: false, is_unique: false, nullable: !is_key }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GraphTable {
    /// Unique within the graph (schema-qualified when outside the schema shown).
    pub name: String,
    /// The browse path that opens this table.
    pub path: Vec<String>,
    pub columns: Vec<GraphColumn>,
    pub estimated_rows: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Relation {
    pub name: String,
    pub from_table: String,
    pub from_columns: Vec<String>,
    pub to_table: String,
    pub to_columns: Vec<String>,
    /// True when guessed from data (MongoDB) rather than a declared foreign key.
    pub inferred: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SchemaGraph {
    pub tables: Vec<GraphTable>,
    pub relations: Vec<Relation>,
}

/// Rows a driver fetched for a cursor: `size + 1` at most, in the order the
/// query returned them (descending for `Before` / `Last`).
pub(crate) struct Fetched {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Row>,
    pub paging_keys: Vec<Vec<Value>>,
    pub edit_keys: Vec<Vec<Value>>,
    /// Whole documents (document stores only), in row order.
    pub documents: Vec<String>,
}

impl PageCursor {
    /// Whether the query must read in descending key order.
    pub(crate) fn descending(&self) -> bool {
        matches!(self, PageCursor::Before { .. } | PageCursor::Last)
    }
}

/// Turns `size + 1` fetched rows into a page with prev/next flags.
pub(crate) fn assemble(mut f: Fetched, cursor: &PageCursor, size: usize, keyset: bool) -> TablePage {
    let extra = f.rows.len() > size;
    f.rows.truncate(size);
    f.paging_keys.truncate(size);
    f.edit_keys.truncate(size);
    f.documents.truncate(size);
    if cursor.descending() {
        f.rows.reverse();
        f.paging_keys.reverse();
        f.edit_keys.reverse();
        f.documents.reverse();
    }
    let (has_prev, has_next) = match cursor {
        PageCursor::First => (false, extra),
        PageCursor::After { .. } => (true, extra),
        PageCursor::Offset { offset } => (*offset > 0, extra),
        PageCursor::Before { .. } => (extra, true),
        PageCursor::Last => (extra, false),
    };
    let offset = match cursor {
        PageCursor::First => Some(0),
        PageCursor::Offset { offset } => Some(*offset),
        _ => None,
    };
    TablePage {
        columns: f.columns,
        first_key: keyset.then(|| f.paging_keys.first().cloned()).flatten(),
        last_key: keyset.then(|| f.paging_keys.last().cloned()).flatten(),
        rows: f.rows,
        row_keys: f.edit_keys,
        documents: f.documents,
        has_prev,
        has_next,
        offset,
    }
}

/// The text form of a key or cell value, as the engines print it back.
pub(crate) fn value_text(v: &Value) -> Option<String> {
    Some(match v {
        Value::Null => return None,
        Value::Bool { v } => v.to_string(),
        Value::Int { v } => v.to_string(),
        Value::Float { v } => v.to_string(),
        Value::Decimal { v }
        | Value::Text { v }
        | Value::Date { v }
        | Value::Time { v }
        | Value::Uuid { v }
        | Value::Json { v } => v.clone(),
        Value::Timestamp { v, .. } => v.clone(),
        Value::Bytes { v } => {
            let mut s = String::with_capacity(2 + v.len() * 2);
            s.push_str("\\x");
            for b in v {
                s.push_str(&format!("{b:02x}"));
            }
            s
        }
    })
}

/// A Postgres/SQLite string literal. Quotes are doubled; Postgres connections
/// run with `standard_conforming_strings = on`, so backslashes are literal.
pub(crate) fn sql_string(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// A MySQL string literal that can't break out of its quotes: the text is
/// sent as hex and converted, whatever `sql_mode` says about backslashes.
pub(crate) fn mysql_string(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    let hex: String = s.bytes().map(|b| format!("{b:02X}")).collect();
    format!("CONVERT(X'{hex}' USING utf8mb4)")
}

/// Accepts only what a SQL numeric literal may contain.
pub(crate) fn numeric_literal(s: &str) -> Option<&str> {
    let t = s.trim();
    let digits = t.strip_prefix('-').unwrap_or(t);
    let ok = !digits.is_empty()
        && digits.chars().all(|c| c.is_ascii_digit() || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-')
        && digits.chars().next().is_some_and(|c| c.is_ascii_digit() || c == '.');
    ok.then_some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(i: i64) -> Row {
        Row { cells: vec![Value::Int { v: i }] }
    }

    fn fetched(ids: &[i64]) -> Fetched {
        Fetched {
            columns: vec![],
            rows: ids.iter().map(|&i| row(i)).collect(),
            paging_keys: ids.iter().map(|&i| vec![Value::Int { v: i }]).collect(),
            edit_keys: ids.iter().map(|&i| vec![Value::Int { v: i }]).collect(),
            documents: ids.iter().map(|i| format!("{{\"_id\": {i}}}")).collect(),
        }
    }

    #[test]
    fn forward_pages() {
        let p = assemble(fetched(&[1, 2, 3]), &PageCursor::First, 2, true);
        assert_eq!(p.rows, vec![row(1), row(2)]);
        assert!(!p.has_prev && p.has_next);
        assert_eq!(p.last_key, Some(vec![Value::Int { v: 2 }]));
        assert_eq!(p.offset, Some(0));

        let p = assemble(fetched(&[3]), &PageCursor::After { key: vec![Value::Int { v: 2 }] }, 2, true);
        assert!(p.has_prev && !p.has_next);
    }

    #[test]
    fn backward_pages_come_back_in_order() {
        // `Last` reads descending: 10, 9, 8 → page [9, 10] with more before it.
        let p = assemble(fetched(&[10, 9, 8]), &PageCursor::Last, 2, true);
        assert_eq!(p.rows, vec![row(9), row(10)]);
        assert!(p.has_prev && !p.has_next);
        assert_eq!(p.first_key, Some(vec![Value::Int { v: 9 }]));
        assert_eq!(p.row_keys[0], vec![Value::Int { v: 9 }]);
        assert_eq!(p.documents, vec!["{\"_id\": 9}", "{\"_id\": 10}"]);
    }

    #[test]
    fn offset_mode_has_no_keys() {
        let p = assemble(fetched(&[1, 2]), &PageCursor::Offset { offset: 40 }, 2, false);
        assert_eq!(p.first_key, None);
        assert!(p.has_prev && !p.has_next);
        assert_eq!(p.offset, Some(40));
    }

    #[test]
    fn literals_cannot_escape() {
        assert_eq!(sql_string("it's"), "'it''s'");
        assert_eq!(mysql_string("a'b\\"), "CONVERT(X'6127625C' USING utf8mb4)");
        assert_eq!(numeric_literal("-12.5e3"), Some("-12.5e3"));
        assert_eq!(numeric_literal("1; drop"), None);
        assert_eq!(numeric_literal(""), None);
    }
}

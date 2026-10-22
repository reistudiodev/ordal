//! Keyset page queries shared by the SQL drivers, plus the literal rules
//! each dialect needs. Values are inlined as literals (never concatenated
//! raw): Postgres and SQLite double quotes, MySQL sends text as hex, and
//! numbers are checked before use. That keeps every page query on the text
//! protocol, so rows decode the same way as user queries.

use crate::error::{CoreError, Result};
use crate::table::{mysql_string, numeric_literal, sql_string, value_text, CellEdit, Fetched, PageCursor};
use crate::value::{Value, Window};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Dialect {
    Postgres,
    MySql,
    Sqlite,
}

/// A paging or sort expression and how to write literals compared with it.
#[derive(Clone, Debug)]
pub(crate) struct KeyCol {
    /// Already quoted: `"id"`, `ctid`, `rowid`.
    pub expr: String,
    /// Postgres type to cast literals to (`int8`, `tid`, `timestamptz`).
    pub cast: Option<String>,
}

impl Dialect {
    pub(crate) fn ident(self, name: &str) -> String {
        let q = if self == Dialect::MySql { '`' } else { '"' };
        super::sqlx_common::quote_ident(name, q)
    }

    /// A literal for `v`, compared with or assigned to `col`.
    pub(crate) fn literal(self, v: &Value, cast: Option<&str>) -> Result<String> {
        let bad = |what: &str| CoreError::query(format!("not a valid {what}"));
        Ok(match (self, v) {
            (_, Value::Null) => "NULL".into(),
            (Dialect::Postgres, Value::Bytes { .. }) => format!("{}::bytea", sql_string(&value_text(v).unwrap())),
            (Dialect::Postgres, _) => {
                let text = sql_string(&value_text(v).unwrap());
                match cast {
                    Some(t) => format!("{text}::{t}"),
                    None => text,
                }
            }
            (_, Value::Int { v }) => v.to_string(),
            (_, Value::Bool { v }) => if *v { "1" } else { "0" }.into(),
            (_, Value::Float { v }) if v.is_finite() => format!("{v:?}"),
            (_, Value::Float { .. }) => return Err(bad("number")),
            (_, Value::Decimal { v }) => numeric_literal(v).ok_or_else(|| bad("number"))?.to_string(),
            (_, Value::Bytes { v }) => {
                let hex: String = v.iter().map(|b| format!("{b:02X}")).collect();
                format!("X'{hex}'")
            }
            (Dialect::MySql, other) => mysql_string(&value_text(other).unwrap()),
            (Dialect::Sqlite, other) => sql_string(&value_text(other).unwrap()),
        })
    }
}

const TABLE_ALIAS: &str = "__ordal_t";

/// The hidden columns a page query adds in front of `*`: the sort value
/// (if sorted) then each key, aliased so they can be stripped again.
pub(crate) fn hidden_select(d: Dialect, sort: Option<&KeyCol>, keys: &[KeyCol]) -> (String, usize) {
    let mut parts = Vec::new();
    if let Some(s) = sort {
        parts.push(format!("{} AS {}", s.expr, d.ident("__ordal_s")));
    }
    for (i, k) in keys.iter().enumerate() {
        parts.push(format!("{} AS {}", k.expr, d.ident(&format!("__ordal_k{i}"))));
    }
    let n = parts.len();
    // MySQL only allows `*` first, so take the row as `alias.*`.
    parts.push(format!("{}.*", d.ident(TABLE_ALIAS)));
    (parts.join(", "), n)
}

/// A header sort: the column, its direction, and whether it can hold NULLs.
pub(crate) struct SortCol<'a> {
    pub col: &'a KeyCol,
    pub descending: bool,
    pub nullable: bool,
}

/// `SELECT … FROM relation WHERE … ORDER BY … LIMIT size+1 [OFFSET n]`.
///
/// The key breaks ties and runs in the sort's direction, so the order is a
/// plain tuple order and seeks are row comparisons an index can serve.
/// NULL sort values always come last (native `NULLS LAST` on Postgres and
/// SQLite, which matches index order for ascending sorts).
pub(crate) fn page_sql(
    d: Dialect,
    relation: &str,
    keys: &[KeyCol],
    sort: Option<SortCol<'_>>,
    cursor: &PageCursor,
    size: u32,
) -> Result<(String, usize)> {
    // Sorting by the only key column is just paging the key in that direction.
    let (sort, keys_desc) = match sort {
        Some(s) if keys.len() == 1 && keys[0].expr == s.col.expr => (None, s.descending),
        Some(s) => {
            let desc = s.descending;
            (Some(s), desc)
        }
        None => (None, false),
    };
    let (select, hidden) = hidden_select(d, sort.as_ref().map(|s| s.col), keys);
    let backward = cursor.descending();
    // The direction rows are read in: the sort direction, flipped for Before/Last.
    let read_desc = keys_desc != backward;
    let dir = if read_desc { "DESC" } else { "ASC" };

    let mut order = Vec::new();
    if let Some(s) = &sort {
        let e = &s.col.expr;
        if !s.nullable {
            order.push(format!("{e} {dir}"));
        } else if d == Dialect::MySql {
            order.push(format!("({e} IS NULL) {}", if backward { "DESC" } else { "ASC" }));
            order.push(format!("{e} {dir}"));
        } else {
            order.push(format!("{e} {dir} NULLS {}", if backward { "FIRST" } else { "LAST" }));
        }
    }
    for k in keys {
        order.push(format!("{} {dir}", k.expr));
    }

    let mut filter = None;
    let mut offset = None;
    match cursor {
        PageCursor::First => {}
        PageCursor::Last if !keys.is_empty() => {}
        PageCursor::Offset { offset: o } => offset = Some(*o),
        PageCursor::After { key } | PageCursor::Before { key } if !keys.is_empty() => {
            filter = Some(seek(d, keys, sort.as_ref(), key, read_desc, backward)?);
        }
        _ => return Err(CoreError::unsupported("this relation has no key; use page offsets")),
    }

    let mut sql = format!("SELECT {select} FROM {relation} AS {}", d.ident(TABLE_ALIAS));
    if let Some(f) = filter {
        sql.push_str(&format!(" WHERE {f}"));
    }
    if !order.is_empty() {
        sql.push_str(&format!(" ORDER BY {}", order.join(", ")));
    }
    sql.push_str(&format!(" LIMIT {}", size as u64 + 1));
    if let Some(o) = offset {
        sql.push_str(&format!(" OFFSET {o}"));
    }
    Ok((sql, hidden))
}

/// The WHERE clause that starts a page right after `cursor_key` in reading
/// order (`read_desc`). `backward` tells where NULL sort values sit.
fn seek(d: Dialect, keys: &[KeyCol], sort: Option<&SortCol<'_>>, cursor_key: &[Value], read_desc: bool, backward: bool) -> Result<String> {
    let expected = keys.len() + usize::from(sort.is_some());
    if cursor_key.len() != expected {
        return Err(CoreError::invalid("page cursor does not match this table's key"));
    }
    let (sort_value, key_values) = match sort {
        Some(_) => (Some(&cursor_key[0]), &cursor_key[1..]),
        None => (None, cursor_key),
    };
    let cmp = if read_desc { "<" } else { ">" };
    let lits = keys
        .iter()
        .zip(key_values)
        .map(|(k, v)| d.literal(v, k.cast.as_deref()))
        .collect::<Result<Vec<_>>>()?;
    let tuple = |items: Vec<String>| if items.len() == 1 { items[0].clone() } else { format!("({})", items.join(", ")) };
    let key_exprs: Vec<String> = keys.iter().map(|k| k.expr.clone()).collect();
    let key_cmp = format!("{} {cmp} {}", tuple(key_exprs.clone()), tuple(lits.clone()));

    let Some(s) = sort else { return Ok(key_cmp) };
    let sv = sort_value.unwrap();
    let e = &s.col.expr;
    if matches!(sv, Value::Null) {
        // NULLs sort last: forward stays among NULLs, backward may leave them.
        return Ok(if backward {
            format!("({e} IS NOT NULL OR ({e} IS NULL AND {key_cmp}))")
        } else {
            format!("({e} IS NULL AND {key_cmp})")
        });
    }
    let lit = d.literal(sv, s.col.cast.as_deref())?;
    // (sort, key) as one tuple: an index on the sort column can serve it.
    let mut all = vec![e.clone()];
    all.extend(key_exprs);
    let mut all_lits = vec![lit];
    all_lits.extend(lits);
    let tuple_cmp = format!("{} {cmp} {}", tuple(all), tuple(all_lits));
    Ok(match (s.nullable, backward) {
        (false, _) => tuple_cmp,
        (true, false) => format!("({tuple_cmp} OR {e} IS NULL)"),
        (true, true) => format!("({tuple_cmp} AND {e} IS NOT NULL)"),
    })
}

/// Strips the hidden columns a page query added. The paging key is every
/// hidden cell; the edit key is the key part only, when the key is a real
/// primary key (`ctid` moves when a row is updated, so it never edits).
pub(crate) fn split_hidden(w: Window, hidden: usize, sorted: bool, keys_edit_rows: bool) -> Fetched {
    let key_start = usize::from(sorted);
    let mut rows = Vec::with_capacity(w.rows.len());
    let mut paging_keys = Vec::with_capacity(w.rows.len());
    let mut edit_keys = Vec::new();
    for mut row in w.rows {
        let visible = row.cells.split_off(hidden.min(row.cells.len()));
        if keys_edit_rows {
            edit_keys.push(row.cells[key_start..].to_vec());
        }
        paging_keys.push(row.cells);
        rows.push(crate::value::Row { cells: visible });
    }
    let columns = w.columns.into_iter().skip(hidden).collect();
    Fetched { columns, rows, paging_keys, edit_keys, documents: Vec::new() }
}

/// One `UPDATE … SET col = value WHERE key = …` per edit, with typed literals.
/// `types` gives the cast for each column (Postgres) and must contain the
/// key columns and every edited column.
pub(crate) fn update_statements(
    d: Dialect,
    relation: &str,
    key_columns: &[String],
    types: &dyn Fn(&str) -> Option<String>,
    edits: &[CellEdit],
) -> Result<Vec<String>> {
    if key_columns.is_empty() {
        return Err(CoreError::unsupported("rows without a primary key can't be edited"));
    }
    edits
        .iter()
        .map(|e| {
            if e.key.len() != key_columns.len() {
                return Err(CoreError::invalid("row key does not match the table's primary key"));
            }
            if key_columns.contains(&e.column) {
                return Err(CoreError::unsupported("primary key columns can't be edited here"));
            }
            let cast = types(&e.column).ok_or_else(|| CoreError::not_found(format!("column `{}`", e.column)))?;
            let set = d.literal(&e.value, (d == Dialect::Postgres).then_some(cast.as_str()))?;
            let filter = key_columns
                .iter()
                .zip(&e.key)
                .map(|(k, v)| {
                    let kc = types(k).unwrap_or_default();
                    Ok(format!("{} = {}", d.ident(k), d.literal(v, (d == Dialect::Postgres).then_some(kc.as_str()))?))
                })
                .collect::<Result<Vec<_>>>()?
                .join(" AND ");
            Ok(format!("UPDATE {relation} SET {} = {set} WHERE {filter}", d.ident(&e.column)))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id() -> Vec<KeyCol> {
        vec![KeyCol { expr: "\"id\"".into(), cast: Some("int8".into()) }]
    }

    #[test]
    fn first_and_after() {
        let (sql, hidden) = page_sql(Dialect::Postgres, "\"t\"", &id(), None, &PageCursor::First, 100).unwrap();
        assert_eq!(
            sql,
            "SELECT \"id\" AS \"__ordal_k0\", \"__ordal_t\".* FROM \"t\" AS \"__ordal_t\" ORDER BY \"id\" ASC LIMIT 101"
        );
        assert_eq!(hidden, 1);
        let after = PageCursor::After { key: vec![Value::Int { v: 100 }] };
        let (sql, _) = page_sql(Dialect::Postgres, "\"t\"", &id(), None, &after, 100).unwrap();
        assert!(sql.contains("WHERE \"id\" > '100'::int8 ORDER BY \"id\" ASC LIMIT 101"), "{sql}");
    }

    #[test]
    fn last_reads_backwards() {
        let (sql, _) = page_sql(Dialect::Sqlite, "\"t\"", &[KeyCol { expr: "rowid".into(), cast: None }], None, &PageCursor::Last, 10).unwrap();
        assert!(sql.ends_with("ORDER BY rowid DESC LIMIT 11"), "{sql}");
    }

    #[test]
    fn sorted_seek_keeps_nulls_last() {
        let s = KeyCol { expr: "\"name\"".into(), cast: Some("text".into()) };
        let sort = || Some(SortCol { col: &s, descending: false, nullable: true });
        let after = PageCursor::After { key: vec![Value::Text { v: "bob".into() }, Value::Int { v: 7 }] };
        let (sql, hidden) = page_sql(Dialect::Postgres, "\"t\"", &id(), sort(), &after, 10).unwrap();
        assert_eq!(hidden, 2);
        assert!(sql.contains("WHERE ((\"name\", \"id\") > ('bob'::text, '7'::int8) OR \"name\" IS NULL)"), "{sql}");
        assert!(sql.contains("ORDER BY \"name\" ASC NULLS LAST, \"id\" ASC"), "{sql}");
        let (sql, _) = page_sql(Dialect::MySql, "`t`", &id(), sort(), &PageCursor::First, 10).unwrap();
        assert!(sql.contains("ORDER BY (\"name\" IS NULL) ASC, \"name\" ASC"), "{sql}");
    }

    #[test]
    fn sorting_by_the_key_is_key_paging() {
        let k = id();
        let sort = Some(SortCol { col: &k[0], descending: true, nullable: false });
        let (sql, hidden) = page_sql(Dialect::Postgres, "\"t\"", &k, sort, &PageCursor::First, 10).unwrap();
        assert_eq!(hidden, 1);
        assert!(sql.ends_with("ORDER BY \"id\" DESC LIMIT 11"), "{sql}");
    }

    #[test]
    fn not_null_sorts_use_a_tuple_seek() {
        let s = KeyCol { expr: "\"n\"".into(), cast: None };
        let before = PageCursor::Before { key: vec![Value::Int { v: 3 }, Value::Int { v: 9 }] };
        let sort = Some(SortCol { col: &s, descending: true, nullable: false });
        let (sql, _) = page_sql(Dialect::Sqlite, "\"t\"", &[KeyCol { expr: "\"id\"".into(), cast: None }], sort, &before, 10).unwrap();
        assert!(sql.contains("WHERE (\"n\", \"id\") > (3, 9) ORDER BY \"n\" ASC, \"id\" ASC"), "{sql}");
    }

    #[test]
    fn keyless_relations_need_offsets() {
        let after = PageCursor::After { key: vec![] };
        assert!(page_sql(Dialect::MySql, "`t`", &[], None, &after, 10).is_err());
        let (sql, _) = page_sql(Dialect::MySql, "`t`", &[], None, &PageCursor::Offset { offset: 20 }, 10).unwrap();
        assert_eq!(sql, "SELECT `__ordal_t`.* FROM `t` AS `__ordal_t` LIMIT 11 OFFSET 20");
    }

    #[test]
    fn updates_cast_and_filter_by_key() {
        let types = |c: &str| Some(if c == "id" { "int8" } else { "text" }.to_string());
        let edits = [CellEdit { key: vec![Value::Int { v: 5 }], column: "name".into(), value: Value::Text { v: "O'Neil".into() } }];
        let sql = update_statements(Dialect::Postgres, "\"public\".\"t\"", &["id".into()], &types, &edits).unwrap();
        assert_eq!(sql, vec!["UPDATE \"public\".\"t\" SET \"name\" = 'O''Neil'::text WHERE \"id\" = '5'::int8"]);
        let null = [CellEdit { key: vec![Value::Int { v: 5 }], column: "name".into(), value: Value::Null }];
        assert!(update_statements(Dialect::Sqlite, "\"t\"", &["id".into()], &types, &null).unwrap()[0].contains("= NULL WHERE"));
        let pk = [CellEdit { key: vec![Value::Int { v: 5 }], column: "id".into(), value: Value::Int { v: 6 } }];
        assert!(update_statements(Dialect::Sqlite, "\"t\"", &["id".into()], &types, &pk).is_err());
    }

    #[test]
    fn mysql_literals_are_hex() {
        assert_eq!(Dialect::MySql.literal(&Value::Text { v: "x'".into() }, None).unwrap(), "CONVERT(X'7827' USING utf8mb4)");
        assert_eq!(Dialect::MySql.literal(&Value::Bool { v: true }, None).unwrap(), "1");
        assert!(Dialect::MySql.literal(&Value::Decimal { v: "1;drop".into() }, None).is_err());
    }
}

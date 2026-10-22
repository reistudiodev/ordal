//! Shared helpers for the integration tests.
//!
//! Server engines read their URL from `ORDAL_TEST_<ENGINE>_URL` (see
//! `docker-compose.test.yml` and `scripts/test-integration.sh`). When it is
//! unset or the server is unreachable, the test prints a note and passes, so
//! `cargo test` works on machines without Docker.

#![allow(dead_code)]

use std::sync::Arc;
use std::time::Duration;

use ordal_core::{parse_connection_url, ColumnInfo, ConnectionManager, CoreError, Row, Session};

pub struct Fixture {
    _dir: tempfile::TempDir,
    pub manager: Arc<ConnectionManager>,
    pub session: Arc<Session>,
}

/// Opens a session for `url` through the public API (save, then open).
pub async fn open_url(url: &str) -> Result<Fixture, CoreError> {
    let dir = tempfile::tempdir().unwrap();
    let manager = ConnectionManager::with_directory(dir.path().to_string_lossy().into(), false)?;
    let parsed = parse_connection_url(url.into())?;
    let saved = manager.save(parsed.config, parsed.password)?;
    let session = manager.open(saved.id).await?;
    Ok(Fixture { _dir: dir, manager, session })
}

/// The fixture for `ORDAL_TEST_<engine>_URL`, or None (test skipped).
pub async fn fixture(engine: &str) -> Option<Fixture> {
    let var = format!("ORDAL_TEST_{engine}_URL");
    let Ok(url) = std::env::var(&var) else {
        eprintln!("skipped: {var} not set (docker not available?)");
        return None;
    };
    match open_url(&url).await {
        Ok(f) => Some(f),
        Err(e @ (CoreError::Connection { .. } | CoreError::Timeout { .. })) => {
            eprintln!("skipped: {engine} unreachable: {e}");
            None
        }
        Err(e) => panic!("{engine}: {e}"),
    }
}

/// Runs a query to completion, pulling pages of `page` rows.
/// Returns the columns, all rows, and the largest page seen.
pub async fn run(session: &Session, sql: &str, page: u32) -> Result<(Vec<ColumnInfo>, Vec<Row>, usize), CoreError> {
    let cursor = session.query(sql.into(), None)?;
    let columns = cursor.columns().await?;
    let mut rows = Vec::new();
    let mut largest = 0;
    loop {
        let p = cursor.next_page(page).await?;
        largest = largest.max(p.rows.len());
        rows.extend(p.rows);
        if p.done {
            break;
        }
    }
    Ok((columns, rows, largest))
}

pub async fn exec(session: &Session, sql: &str) {
    if let Err(e) = run(session, sql, 1000).await {
        panic!("`{sql}` failed: {e}");
    }
}

/// Starts `sql`, cancels it after a moment, and checks it stops promptly.
pub async fn assert_cancels(session: &Session, sql: &str) {
    let cursor = session.query(sql.into(), None).unwrap();
    let c = cursor.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        c.cancel();
    });
    let result = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match cursor.next_page(500).await {
                Ok(p) if p.done => return Ok(()),
                Ok(_) => continue,
                Err(e) => return Err(e),
            }
        }
    })
    .await
    .expect("cancel did not stop the query within 10 s");
    assert_eq!(result, Err(CoreError::Cancelled));
    // The session still works afterwards.
    session.ping().await.unwrap();
}

use ordal_core::{CellEdit, PageCursor, SortSpec, TablePage, Value};

/// Every row, walking pages from the first to the last with keyset cursors.
pub async fn walk_forward(s: &Session, path: &[String], size: u32, sort: Option<SortSpec>) -> Vec<ordal_core::Row> {
    let mut rows = Vec::new();
    let mut page: TablePage = s.fetch_page(path.to_vec(), PageCursor::First, size, sort.clone()).await.unwrap();
    loop {
        assert!(page.rows.len() <= size as usize);
        rows.extend(page.rows.clone());
        if !page.has_next {
            return rows;
        }
        let cursor = match &page.last_key {
            Some(key) => PageCursor::After { key: key.clone() },
            None => PageCursor::Offset { offset: page.offset.unwrap() + page.rows.len() as u64 },
        };
        let next = s.fetch_page(path.to_vec(), cursor, size, sort.clone()).await.unwrap();
        page = TablePage { offset: next.offset.or(page.offset.map(|o| o + page.rows.len() as u64)), ..next };
    }
}

/// Every row, walking backwards from the last page; returned in table order.
pub async fn walk_backward(s: &Session, path: &[String], size: u32, sort: Option<SortSpec>) -> Vec<ordal_core::Row> {
    let mut pages = Vec::new();
    let mut page = s.fetch_page(path.to_vec(), PageCursor::Last, size, sort.clone()).await.unwrap();
    loop {
        pages.push(page.rows.clone());
        if !page.has_prev {
            break;
        }
        let key = page.first_key.clone().expect("keyset page");
        page = s.fetch_page(path.to_vec(), PageCursor::Before { key }, size, sort.clone()).await.unwrap();
    }
    pages.into_iter().rev().flatten().collect()
}

pub fn int(v: &Value) -> i64 {
    match v {
        Value::Int { v } => *v,
        other => panic!("not an int: {other:?}"),
    }
}

/// The name each test row gets: NULL for every 10th id, else n00..n36.
pub fn expected_name(id: i64) -> Option<String> {
    (id % 10 != 0).then(|| format!("n{:02}", id % 37))
}

/// The paging, sorting and editing contract for a SQL table created with
/// 1000 rows of `(id int primary key, name varchar(20) null)` using
/// `expected_name`, plus `ordal_parent` / `ordal_child` linked by a
/// foreign key under `graph_path`.
pub async fn sql_table_suite(s: &Session, path: Vec<String>, graph_path: Vec<String>) {
    let ids = |rows: &[ordal_core::Row]| rows.iter().map(|r| int(&r.cells[0])).collect::<Vec<_>>();
    let all: Vec<i64> = (1..=1000).collect();

    let meta = s.table_meta(path.clone()).await.unwrap();
    assert_eq!(meta.key_columns, vec!["id".to_string()]);
    assert!(meta.editable, "{:?}", meta.read_only_reason);
    let name_col = meta.columns.iter().find(|c| c.name == "name").unwrap();
    assert!(name_col.nullable && name_col.editable);
    assert!(!meta.columns[0].editable, "primary key columns are not editable");

    // Keyset paging both ways visits every row exactly once.
    assert_eq!(ids(&walk_forward(s, &path, 64, None).await), all);
    assert_eq!(ids(&walk_backward(s, &path, 64, None).await), all);

    // Sorting by the key itself is key paging in that direction.
    let desc_ids: Vec<i64> = (1..=1000).rev().collect();
    let by_id = Some(SortSpec { column: "id".into(), descending: true });
    assert_eq!(ids(&walk_forward(s, &path, 64, by_id.clone()).await), desc_ids);
    assert_eq!(ids(&walk_backward(s, &path, 64, by_id).await), desc_ids);

    // Sorted paging: name ascending/descending, NULLs last, id breaks ties.
    for desc in [false, true] {
        let mut expected = all.clone();
        expected.sort_by(|a, b| {
            let (na, nb) = (expected_name(*a), expected_name(*b));
            // Ties break on the key in the sort's direction; NULLs always last.
            let by_id = if desc { b.cmp(a) } else { a.cmp(b) };
            match (na, nb) {
                (None, None) => by_id,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (Some(_), None) => std::cmp::Ordering::Less,
                (Some(x), Some(y)) => (if desc { y.cmp(&x) } else { x.cmp(&y) }).then(by_id),
            }
        });
        let sort = Some(SortSpec { column: "name".into(), descending: desc });
        assert_eq!(ids(&walk_forward(s, &path, 50, sort.clone()).await), expected, "forward, desc={desc}");
        assert_eq!(ids(&walk_backward(s, &path, 50, sort).await), expected, "backward, desc={desc}");
    }

    // An explicit jump.
    let page = s.fetch_page(path.clone(), PageCursor::Offset { offset: 500 }, 10, None).await.unwrap();
    assert_eq!(int(&page.rows[0].cells[0]), 501);
    assert!(page.has_prev && page.has_next);

    let count = s.row_count(path.clone(), true).await.unwrap();
    assert_eq!((count.count, count.exact), (1000, true));

    // Edits: quotes and backslashes survive, NULL works, keys come from the page.
    let first = s.fetch_page(path.clone(), PageCursor::First, 5, None).await.unwrap();
    let key = first.row_keys[4].clone();
    assert_eq!(key, vec![Value::Int { v: 5 }]);
    let tricky = r#"O'Neil "q" \ back"#.to_string();
    let edits = vec![
        CellEdit { key: key.clone(), column: "name".into(), value: Value::Text { v: tricky.clone() } },
        CellEdit { key: vec![Value::Int { v: 6 }], column: "name".into(), value: Value::Null },
    ];
    let preview = s.preview_edits(path.clone(), edits.clone()).await.unwrap();
    assert!(preview[0].starts_with("UPDATE "), "{preview:?}");
    assert_eq!(s.apply_edits(path.clone(), edits).await.unwrap(), 2);
    let after = s.fetch_page(path.clone(), PageCursor::First, 6, None).await.unwrap();
    assert_eq!(after.rows[4].cells[1], Value::Text { v: tricky });
    assert_eq!(after.rows[5].cells[1], Value::Null);

    // A batch with a missing row saves nothing.
    let bad = vec![
        CellEdit { key: vec![Value::Int { v: 7 }], column: "name".into(), value: Value::Text { v: "changed".into() } },
        CellEdit { key: vec![Value::Int { v: 99_999 }], column: "name".into(), value: Value::Text { v: "x".into() } },
    ];
    assert!(s.apply_edits(path.clone(), bad).await.is_err());
    let row7 = s.fetch_page(path.clone(), PageCursor::Offset { offset: 6 }, 1, None).await.unwrap();
    assert_eq!(row7.rows[0].cells[1], expected_name(7).map_or(Value::Null, |v| Value::Text { v }));

    // Relations.
    let graph = s.schema_graph(graph_path).await.unwrap();
    let rel = graph.relations.iter().find(|r| r.from_table.ends_with("ordal_child")).expect("child → parent relation");
    assert!(rel.to_table.ends_with("ordal_parent"));
    assert_eq!(rel.from_columns, vec!["parent_id".to_string()]);
    assert_eq!(rel.to_columns, vec!["id".to_string()]);
    assert!(!rel.inferred);

    // Column flags on `ordal_flags (id identity PK, code unique not null, note nullable)`.
    let flags = graph.tables.iter().find(|t| t.name.ends_with("ordal_flags")).expect("ordal_flags in the graph");
    let col = |n: &str| flags.columns.iter().find(|c| c.name == n).unwrap();
    let (id, code, note) = (col("id"), col("code"), col("note"));
    assert!(id.is_key && id.is_identity && !id.nullable, "{id:?}");
    assert!(code.is_unique && !code.nullable && !code.is_key, "{code:?}");
    assert!(note.nullable && !note.is_unique && !note.is_identity, "{note:?}");
}

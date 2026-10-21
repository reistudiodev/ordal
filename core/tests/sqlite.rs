//! SQLite runs everywhere (no Docker), so this suite also proves the shared
//! driver contract: browse, typed values, paging, cancel, read-only.

mod common;

use common::{assert_cancels, exec, open_url, run};
use dbclient_core::{parse_connection_url, CoreError, NodeKind, StatementKind, Value};

async fn fixture() -> (tempfile::TempDir, common::Fixture) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("it.db");
    std::fs::File::create(&path).unwrap();
    let f = open_url(&format!("sqlite://{}", path.display())).await.unwrap();
    exec(
        &f.session,
        "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, flag BOOLEAN, \
         data BLOB, at DATETIME, doc JSON); \
         INSERT INTO t VALUES (1, 'ann', 1.5, 1, x'0aff', '2024-01-02 03:04:05', '{\"a\":1}'), \
                              (2, 'bob', NULL, 0, NULL, NULL, NULL); \
         CREATE VIEW v AS SELECT name FROM t;",
    )
    .await;
    (dir, f)
}

#[tokio::test]
async fn server_info_and_ping() {
    let (_d, f) = fixture().await;
    assert_eq!(f.session.server_info().await.unwrap().engine, "SQLite");
    assert!(f.session.ping().await.unwrap() >= 0.0);
}

#[tokio::test]
async fn typed_values_round_trip() {
    let (_d, f) = fixture().await;
    let (cols, rows, _) = run(&f.session, "SELECT * FROM t ORDER BY id", 100).await.unwrap();
    assert_eq!(cols.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["id", "name", "score", "flag", "data", "at", "doc"]);
    assert_eq!(
        rows[0].cells,
        vec![
            Value::Int { v: 1 },
            Value::Text { v: "ann".into() },
            Value::Float { v: 1.5 },
            Value::Bool { v: true },
            Value::Bytes { v: vec![0x0a, 0xff] },
            Value::Timestamp { v: "2024-01-02 03:04:05".into(), has_tz: false },
            // SQLite has no JSON type; sqlx reports a declared JSON column as TEXT.
            Value::Text { v: "{\"a\":1}".into() },
        ]
    );
    assert_eq!(rows[1].cells[2], Value::Null);
    assert_eq!(rows[1].cells[3], Value::Bool { v: false });
}

#[tokio::test]
async fn browse_tree() {
    let (_d, f) = fixture().await;
    let s = &f.session;
    let dbs = s.list_children(vec![]).await.unwrap();
    assert_eq!(dbs[0].name, "main");
    let folders = s.list_children(vec!["main".into()]).await.unwrap();
    assert_eq!(folders.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["Tables", "Views"]);
    let tables = s.list_children(vec!["main".into(), "Tables".into()]).await.unwrap();
    assert_eq!(tables.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["t"]);
    let views = s.list_children(vec!["main".into(), "Views".into()]).await.unwrap();
    assert_eq!(views[0].kind, NodeKind::View);
    let cols = s.list_children(vec!["main".into(), "Tables".into(), "t".into()]).await.unwrap();
    assert_eq!(cols[0].name, "id");
    assert_eq!(cols[0].detail.as_deref(), Some("integer · PK"));
    assert_eq!(cols[1].detail.as_deref(), Some("text · not null"));
}

#[tokio::test]
async fn streams_100k_rows_in_pages() {
    let (_d, f) = fixture().await;
    let sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000) SELECT x FROM c";
    let (cols, rows, largest) = run(&f.session, sql, 500).await.unwrap();
    assert_eq!(cols.len(), 1);
    assert_eq!(rows.len(), 100_000);
    assert!(largest <= 500, "page was {largest} rows");
    assert_eq!(rows.last().unwrap().cells[0], Value::Int { v: 100_000 });
}

#[tokio::test]
async fn empty_result_still_has_columns() {
    let (_d, f) = fixture().await;
    let (cols, rows, _) = run(&f.session, "SELECT id, name FROM t WHERE 0", 100).await.unwrap();
    assert_eq!(cols.len(), 2);
    assert!(rows.is_empty());
}

#[tokio::test]
async fn window_and_count() {
    let (_d, f) = fixture().await;
    let path: Vec<String> = ["main", "Tables", "t"].map(String::from).into();
    let w = f.session.fetch_window(path.clone(), 1, 10).await.unwrap();
    assert_eq!(w.columns.len(), 7);
    assert_eq!(w.rows.len(), 1);
    assert_eq!(w.rows[0].cells[0], Value::Int { v: 2 });
    let c = f.session.row_count(path).await.unwrap();
    assert_eq!((c.count, c.exact), (2, true));
}

#[tokio::test]
async fn writes_report_rows_affected() {
    let (_d, f) = fixture().await;
    let cursor = f.session.query("UPDATE t SET name = 'x' WHERE id = 1".into(), None).unwrap();
    assert!(cursor.next_page(10).await.unwrap().done);
    assert_eq!(cursor.rows_affected(), Some(1));
}

#[tokio::test]
async fn errors_are_mapped() {
    let (_d, f) = fixture().await;
    let err = run(&f.session, "SELEC 1", 10).await.unwrap_err();
    assert!(matches!(err, CoreError::Query { .. }), "{err:?}");
    let missing = open_url("sqlite:///definitely/not/here.db").await.err().unwrap();
    assert!(matches!(missing, CoreError::Connection { .. } | CoreError::Query { .. }), "{missing:?}");
}

#[tokio::test]
async fn cancel_stops_a_long_statement() {
    let (_d, f) = fixture().await;
    // Never yields a row, so only the progress handler can stop it.
    assert_cancels(&f.session, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c").await;
}

#[tokio::test]
async fn read_only_connections_refuse_writes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ro.db");
    std::fs::File::create(&path).unwrap();
    let manager = dbclient_core::ConnectionManager::with_directory(dir.path().to_string_lossy().into(), false).unwrap();
    let mut config = parse_connection_url(format!("sqlite://{}", path.display())).unwrap().config;
    config.read_only = true;
    let saved = manager.save(config, None).unwrap();
    let s = manager.open(saved.id).await.unwrap();
    assert_eq!(s.classify("DROP TABLE x".into()), StatementKind::Destructive);
    assert!(matches!(s.query("CREATE TABLE x (a)".into(), None), Err(CoreError::ReadOnly { .. })));
    run(&s, "SELECT 1", 10).await.unwrap();
}

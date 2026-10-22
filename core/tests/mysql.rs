//! Needs `DBCLIENT_TEST_MYSQL_URL` (MySQL 8) and/or `DBCLIENT_TEST_MARIADB_URL`
//! (MariaDB 10.11); each is skipped when unset.

mod common;

use common::{assert_cancels, exec, fixture, run};
use dbclient_core::{Value, ValueKind};

/// 100 000 rows without recursive CTE limits (which differ between engines).
fn hundred_thousand() -> String {
    let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
                  UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)";
    format!(
        "SELECT a.n + b.n * 10 + c.n * 100 + d.n * 1000 + e.n * 10000 AS x \
         FROM {digits} a, {digits} b, {digits} c, {digits} d, {digits} e"
    )
}

async fn suite(engine: &str, expect_name: &str) {
    let Some(f) = fixture(engine).await else { return };
    let s = &f.session;
    assert_eq!(s.server_info().await.unwrap().engine, expect_name);

    let (cols, rows, _) = run(
        s,
        "SELECT 1, 1.5e0, CAST(12.34 AS DECIMAL(5,2)), 'x', CAST('2024-01-02' AS DATE), \
         CAST('2024-01-02 03:04:05' AS DATETIME), JSON_OBJECT('a', 1), NULL, x'0aff'",
        10,
    )
    .await
    .unwrap();
    let r = &rows[0].cells;
    assert_eq!(r[0], Value::Int { v: 1 });
    assert_eq!(r[1], Value::Float { v: 1.5 });
    assert_eq!(r[2], Value::Decimal { v: "12.34".into() });
    assert_eq!(r[3], Value::Text { v: "x".into() });
    assert_eq!(r[4], Value::Date { v: "2024-01-02".into() });
    assert_eq!(r[5], Value::Timestamp { v: "2024-01-02 03:04:05".into(), has_tz: false });
    // MariaDB's JSON is an alias for LONGTEXT.
    assert!(matches!(cols[6].kind, ValueKind::Json | ValueKind::Text));
    assert_eq!(r[7], Value::Null);
    assert_eq!(r[8], Value::Bytes { v: vec![0x0a, 0xff] });

    let (_, rows, largest) = run(s, &hundred_thousand(), 500).await.unwrap();
    assert_eq!(rows.len(), 100_000);
    assert!(largest <= 500);

    let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
                  UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)";
    exec(
        s,
        &format!(
            "DROP TABLE IF EXISTS dbclient_child, dbclient_parent, dbclient_it, dbclient_flags; \
             CREATE TABLE dbclient_flags (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(20) UNIQUE NOT NULL, note TEXT); \
             CREATE TABLE dbclient_it (id INT PRIMARY KEY, name VARCHAR(20) NULL) COLLATE utf8mb4_bin; \
             INSERT INTO dbclient_it SELECT x, IF(x % 10 = 0, NULL, CONCAT('n', LPAD(x % 37, 2, '0'))) \
               FROM (SELECT a.n + b.n * 10 + c.n * 100 + 1 AS x FROM {digits} a, {digits} b, {digits} c) t; \
             CREATE TABLE dbclient_parent (id INT PRIMARY KEY); \
             CREATE TABLE dbclient_child (id INT PRIMARY KEY, parent_id INT, FOREIGN KEY (parent_id) REFERENCES dbclient_parent(id))"
        ),
    )
    .await;
    let db = s.config().database;
    let path: Vec<String> = vec![db.clone(), "Tables".into(), "dbclient_it".into()];
    let tables = s.list_children(path[..2].to_vec()).await.unwrap();
    assert!(tables.iter().any(|n| n.name == "dbclient_it"));
    let cols = s.list_children(path.clone()).await.unwrap();
    // MySQL 8 says `int`, MariaDB keeps the display width: `int(11)`.
    let detail = cols[0].detail.clone().unwrap_or_default();
    assert!(detail.starts_with("int") && detail.ends_with("· PK"), "{detail}");
    common::sql_table_suite(s, path, vec![db.clone()]).await;

    assert_cancels(s, "SELECT SLEEP(30)").await;
    exec(s, "DROP TABLE dbclient_child, dbclient_parent, dbclient_it, dbclient_flags").await;
}

#[tokio::test]
async fn mysql_suite() {
    suite("MYSQL", "MySQL").await;
}

#[tokio::test]
async fn mariadb_suite() {
    suite("MARIADB", "MariaDB").await;
}

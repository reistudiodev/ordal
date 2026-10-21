//! Needs `DBCLIENT_TEST_POSTGRES_URL` (Postgres 16 in Docker); skipped otherwise.

mod common;

use common::{assert_cancels, exec, fixture, run};
use dbclient_core::{CoreError, NodeKind, Value};

#[tokio::test]
async fn postgres_suite() {
    let Some(f) = fixture("POSTGRES").await else { return };
    let s = &f.session;

    let info = s.server_info().await.unwrap();
    assert_eq!(info.engine, "PostgreSQL");
    assert!(info.version.chars().next().is_some_and(|c| c.is_ascii_digit()), "{}", info.version);

    // Typed values over the text protocol.
    let (_, rows, _) = run(
        s,
        "SELECT 1::int4, 2::int8, 1.5::float8, 12.34::numeric, 'x'::text, true, '\\x0aff'::bytea, \
         '2024-01-02'::date, '2024-01-02 03:04:05+00'::timestamptz, \
         'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, '{\"a\": 1}'::jsonb, NULL::text",
        10,
    )
    .await
    .unwrap();
    assert_eq!(
        rows[0].cells,
        vec![
            Value::Int { v: 1 },
            Value::Int { v: 2 },
            Value::Float { v: 1.5 },
            Value::Decimal { v: "12.34".into() },
            Value::Text { v: "x".into() },
            Value::Bool { v: true },
            Value::Bytes { v: vec![0x0a, 0xff] },
            Value::Date { v: "2024-01-02".into() },
            Value::Timestamp { v: "2024-01-02 03:04:05+00".into(), has_tz: true },
            Value::Uuid { v: "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11".into() },
            Value::Json { v: "{\"a\": 1}".into() },
            Value::Null,
        ]
    );

    // Paging.
    let (_, rows, largest) = run(s, "SELECT g FROM generate_series(1, 100000) g", 500).await.unwrap();
    assert_eq!(rows.len(), 100_000);
    assert!(largest <= 500);

    // Browse + windows.
    exec(
        s,
        "DROP TABLE IF EXISTS public.dbclient_it; \
         CREATE TABLE public.dbclient_it (id int PRIMARY KEY, name text NOT NULL); \
         INSERT INTO public.dbclient_it SELECT g, 'n' || g FROM generate_series(1, 1000) g",
    )
    .await;
    let db = s.config().database;
    let schemas = s.list_children(vec![db.clone()]).await.unwrap();
    assert!(schemas.iter().any(|n| n.name == "public" && n.kind == NodeKind::Schema));
    let path: Vec<String> = vec![db.clone(), "public".into(), "Tables".into(), "dbclient_it".into()];
    let tables = s.list_children(path[..3].to_vec()).await.unwrap();
    assert!(tables.iter().any(|n| n.name == "dbclient_it"));
    let cols = s.list_children(path.clone()).await.unwrap();
    assert_eq!(cols[0].detail.as_deref(), Some("integer · PK"));
    let w = s.fetch_window(path.clone(), 500, 10).await.unwrap();
    assert_eq!(w.rows[0].cells[0], Value::Int { v: 501 });
    assert_eq!(s.row_count(path).await.unwrap().count, 1000);

    // Errors.
    let err = run(s, "SELECT * FROM no_such_table", 10).await.unwrap_err();
    match err {
        CoreError::Query { message, position } => {
            assert!(message.contains("no_such_table"));
            assert_eq!(position, Some(15));
        }
        other => panic!("{other:?}"),
    }

    // Cancel (server-side via pg_cancel_backend).
    assert_cancels(s, "SELECT pg_sleep(30)").await;
    exec(s, "DROP TABLE public.dbclient_it").await;
}

/// Phase 1 gate: random access into a 1M-row table stays fast enough to
/// scroll. Needs `scripts/seed-1m.sql` loaded; run with `--ignored`.
#[tokio::test]
#[ignore]
async fn gate_1m_window_latency() {
    let Some(f) = fixture("POSTGRES").await else { return };
    let s = &f.session;
    let path: Vec<String> = vec![s.config().database, "public".into(), "Tables".into(), "events_1m".into()];
    let count = s.row_count(path.clone()).await.unwrap();
    assert!(count.count >= 990_000, "seed the table first: {count:?}");
    for offset in [0u64, 250_000, 500_000, 750_000, 999_500] {
        let start = std::time::Instant::now();
        let w = s.fetch_window(path.clone(), offset, 500).await.unwrap();
        let ms = start.elapsed().as_millis();
        eprintln!("offset {offset:>7}: {} rows in {ms} ms", w.rows.len());
        assert_eq!(w.rows.len(), 500);
        assert!(ms < 1000, "page at offset {offset} took {ms} ms");
    }
}

//! Needs `DBCLIENT_TEST_POSTGRES_URL` (Postgres 16 in Docker); skipped otherwise.

mod common;

use common::{assert_cancels, exec, fixture, run};
use dbclient_core::{CoreError, NodeKind, PageCursor, SortSpec, Value};

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

    // Browse.
    exec(
        s,
        "DROP TABLE IF EXISTS public.dbclient_child, public.dbclient_parent, public.dbclient_it, public.dbclient_flags; \
         CREATE TABLE public.dbclient_flags (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, code text UNIQUE NOT NULL, note text); \
         CREATE TABLE public.dbclient_it (id int PRIMARY KEY, name varchar(20)); \
         INSERT INTO public.dbclient_it SELECT g, CASE WHEN g % 10 = 0 THEN NULL ELSE 'n' || lpad((g % 37)::text, 2, '0') END \
           FROM generate_series(1, 1000) g; \
         CREATE TABLE public.dbclient_parent (id int PRIMARY KEY); \
         CREATE TABLE public.dbclient_child (id int PRIMARY KEY, parent_id int REFERENCES public.dbclient_parent(id))",
    )
    .await;
    let db = s.config().database;
    let schemas = s.list_children(vec![db.clone()]).await.unwrap();
    assert!(schemas.iter().any(|n| n.name == "public" && n.kind == NodeKind::Schema));
    let path: Vec<String> = vec![db.clone(), "public".into(), "Tables".into(), "dbclient_it".into()];
    let cols = s.list_children(path.clone()).await.unwrap();
    assert_eq!(cols[0].detail.as_deref(), Some("integer · PK"));
    common::sql_table_suite(s, path, vec![db.clone(), "public".into()]).await;

    // A table without a primary key still pages by ctid, but can't be edited.
    exec(s, "DROP TABLE IF EXISTS public.dbclient_loose; CREATE TABLE public.dbclient_loose AS SELECT g AS v FROM generate_series(1, 250) g").await;
    let loose: Vec<String> = vec![db.clone(), "public".into(), "Tables".into(), "dbclient_loose".into()];
    let meta = s.table_meta(loose.clone()).await.unwrap();
    assert_eq!(meta.paging, dbclient_core::PagingMode::Keyset);
    assert!(!meta.editable);
    assert_eq!(common::walk_forward(s, &loose, 100, None).await.len(), 250);
    assert_eq!(common::walk_backward(s, &loose, 100, None).await.len(), 250);

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
    exec(s, "DROP TABLE public.dbclient_child, public.dbclient_parent, public.dbclient_it, public.dbclient_loose, public.dbclient_flags").await;
}

/// Phase 1 gate: random access into a 1M-row table stays fast enough to
/// scroll. Needs `scripts/seed-1m.sql` loaded; run with `--ignored`.
#[tokio::test]
#[ignore]
async fn gate_1m_window_latency() {
    let Some(f) = fixture("POSTGRES").await else { return };
    let s = &f.session;
    let path: Vec<String> = vec![s.config().database, "public".into(), "Tables".into(), "events_1m".into()];
    let count = s.row_count(path.clone(), false).await.unwrap();
    assert!(count.count >= 990_000, "seed the table first: {count:?}");
    // Keyset pages cost the same anywhere in the table.
    let mut cursor = PageCursor::Last;
    for step in ["last", "before last", "before that"] {
        let start = std::time::Instant::now();
        let page = s.fetch_page(path.clone(), cursor, 500, None).await.unwrap();
        let ms = start.elapsed().as_millis();
        eprintln!("{step:>12}: {} rows in {ms} ms", page.rows.len());
        assert_eq!(page.rows.len(), 500);
        assert!(ms < 1000, "{step} took {ms} ms");
        cursor = PageCursor::Before { key: page.first_key.unwrap() };
    }
    // Sorted by an indexed column, deep pages stay fast too.
    let sort = Some(SortSpec { column: "created_at".into(), descending: true });
    let start = std::time::Instant::now();
    let page = s.fetch_page(path.clone(), PageCursor::Last, 500, sort).await.unwrap();
    eprintln!("sorted last: {} rows in {} ms", page.rows.len(), start.elapsed().as_millis());
}

//! Needs `DBCLIENT_TEST_MONGODB_URL` (MongoDB 7); skipped otherwise.

mod common;

use common::{exec, fixture, run};
use dbclient_core::{NodeKind, StatementKind, Value};

#[tokio::test]
async fn mongodb_suite() {
    let Some(f) = fixture("MONGODB").await else { return };
    let s = &f.session;
    assert_eq!(s.server_info().await.unwrap().engine, "MongoDB");

    let _ = run(s, r#"{"drop": "dbclient_it"}"#, 10).await;
    for batch in 0..4 {
        let docs: Vec<String> = (0..5000)
            .map(|i| {
                let n = batch * 5000 + i;
                format!(r#"{{"_id": {n}, "name": "n{n}", "even": {}}}"#, n % 2 == 0)
            })
            .collect();
        exec(s, &format!(r#"{{"insert": "dbclient_it", "documents": [{}]}}"#, docs.join(","))).await;
    }

    let (cols, rows, _) =
        run(s, r#"{"find": "dbclient_it", "filter": {"_id": {"$lt": 3}}, "sort": {"_id": 1}}"#, 100).await.unwrap();
    assert_eq!(cols[0].name, "document");
    assert_eq!(rows.len(), 3);
    assert!(matches!(&rows[0].cells[0], Value::Json { v } if v.contains("\"n0\"")));

    let (_, rows, largest) = run(s, r#"{"find": "dbclient_it", "filter": {}}"#, 500).await.unwrap();
    assert_eq!(rows.len(), 20_000);
    assert!(largest <= 500);

    let (_, rows, _) =
        run(s, r#"{"aggregate": "dbclient_it", "pipeline": [{"$group": {"_id": "$even", "n": {"$sum": 1}}}]}"#, 10)
            .await
            .unwrap();
    assert_eq!(rows.len(), 2);

    let db = s.config().database;
    let colls = s.list_children(vec![db.clone()]).await.unwrap();
    assert!(colls.iter().any(|n| n.name == "dbclient_it" && n.kind == NodeKind::Collection));
    let path = vec![db.clone(), "dbclient_it".to_string()];
    let idx = s.list_children(path.clone()).await.unwrap();
    assert!(idx.iter().any(|n| n.name == "_id_"));
    let w = s.fetch_window(path.clone(), 100, 5).await.unwrap();
    assert_eq!(w.rows.len(), 5);
    assert!(s.row_count(path).await.unwrap().count >= 20_000);

    assert_eq!(s.classify(r#"{"dropDatabase": 1}"#.into()), StatementKind::Destructive);
    exec(s, r#"{"drop": "dbclient_it"}"#).await;
}

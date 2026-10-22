//! Needs `ORDAL_TEST_MONGODB_URL` (MongoDB 7); skipped otherwise.

mod common;

use common::{exec, fixture, run};
use ordal_core::{CellEdit, NodeKind, PageCursor, SortSpec, StatementKind, Value};

#[tokio::test]
async fn mongodb_suite() {
    let Some(f) = fixture("MONGODB").await else { return };
    let s = &f.session;
    assert_eq!(s.server_info().await.unwrap().engine, "MongoDB");

    let _ = run(s, r#"{"drop": "ordal_it"}"#, 10).await;
    for batch in 0..4 {
        let docs: Vec<String> = (0..5000)
            .map(|i| {
                let n = batch * 5000 + i;
                format!(r#"{{"_id": {n}, "name": "n{n}", "even": {}}}"#, n % 2 == 0)
            })
            .collect();
        exec(s, &format!(r#"{{"insert": "ordal_it", "documents": [{}]}}"#, docs.join(","))).await;
    }

    let (cols, rows, _) =
        run(s, r#"{"find": "ordal_it", "filter": {"_id": {"$lt": 3}}, "sort": {"_id": 1}}"#, 100).await.unwrap();
    assert_eq!(cols[0].name, "document");
    assert_eq!(rows.len(), 3);
    assert!(matches!(&rows[0].cells[0], Value::Json { v } if v.contains("\"n0\"") && v.contains("$numberInt")));

    let (_, rows, largest) = run(s, r#"{"find": "ordal_it", "filter": {}}"#, 500).await.unwrap();
    assert_eq!(rows.len(), 20_000);
    assert!(largest <= 500);

    let (_, rows, _) =
        run(s, r#"{"aggregate": "ordal_it", "pipeline": [{"$group": {"_id": "$even", "n": {"$sum": 1}}}]}"#, 10)
            .await
            .unwrap();
    assert_eq!(rows.len(), 2);

    let db = s.config().database;
    let colls = s.list_children(vec![db.clone()]).await.unwrap();
    assert!(colls.iter().any(|n| n.name == "ordal_it" && n.kind == NodeKind::Collection));
    let path = vec![db.clone(), "ordal_it".to_string()];
    let idx = s.list_children(path.clone()).await.unwrap();
    assert!(idx.iter().any(|n| n.name == "_id_"));
    // Keyset pages on _id, both directions, cover every document once.
    let fwd = common::walk_forward(s, &path, 1000, None).await;
    assert_eq!(fwd.len(), 20_000);
    assert_eq!(common::walk_backward(s, &path, 1000, None).await, fwd);
    let page = s.fetch_page(path.clone(), PageCursor::First, 5, None).await.unwrap();
    assert_eq!(page.columns.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["_id", "name", "even"]);
    assert_eq!(page.rows[0].cells, vec![Value::Int { v: 0 }, Value::Text { v: "n0".into() }, Value::Bool { v: true }]);
    // Whole documents come along, in stored field order.
    assert_eq!(page.documents.len(), 5);
    assert_eq!(page.documents[0], r#"{"_id":{"$numberInt":"0"},"name":"n0","even":true}"#);
    assert_eq!(s.row_count(path.clone(), true).await.unwrap().count, 20_000);

    // Sorted by a field pages with skip.
    let sort = Some(SortSpec { column: "name".into(), descending: true });
    let sorted = s.fetch_page(path.clone(), PageCursor::First, 3, sort).await.unwrap();
    assert!(sorted.first_key.is_none());
    assert_eq!(sorted.rows[0].cells[1], Value::Text { v: "n9999".into() });

    // Edits keep the field's type: `even` stays a bool, a number stays a number.
    let meta = s.table_meta(path.clone()).await.unwrap();
    assert_eq!(meta.key_columns, vec!["_id".to_string()]);
    let key = page.row_keys[0].clone();
    let edits = vec![
        CellEdit { key: key.clone(), column: "even".into(), value: Value::Text { v: "false".into() } },
        CellEdit { key: key.clone(), column: "name".into(), value: Value::Text { v: "renamed".into() } },
    ];
    assert!(s.preview_edits(path.clone(), edits.clone()).await.unwrap()[0].contains("$set"));
    assert_eq!(s.apply_edits(path.clone(), edits).await.unwrap(), 2);
    let page = s.fetch_page(path.clone(), PageCursor::First, 1, None).await.unwrap();
    assert_eq!(page.rows[0].cells[1..], [Value::Text { v: "renamed".into() }, Value::Bool { v: false }]);
    let wrong = vec![CellEdit { key, column: "even".into(), value: Value::Text { v: "maybe".into() } }];
    assert!(s.apply_edits(path.clone(), wrong).await.is_err());

    // Inferred relations: orders.userId holds ids from users.
    let _ = run(s, r#"{"drop": "users"}"#, 10).await;
    let _ = run(s, r#"{"drop": "orders"}"#, 10).await;
    exec(s, r#"{"insert": "users", "documents": [{"_id": {"$oid": "65f000000000000000000001"}, "name": "ann", "email": "ann@example.com"}]}"#).await;
    exec(s, r#"{"createIndexes": "users", "indexes": [{"key": {"email": 1}, "name": "email_1", "unique": true}]}"#).await;
    exec(s, r#"{"insert": "orders", "documents": [{"total": 5, "userId": {"$oid": "65f000000000000000000001"}}]}"#).await;
    let graph = s.schema_graph(vec![db.clone()]).await.unwrap();
    let rel = graph.relations.iter().find(|r| r.from_table == "orders").expect("orders → users");
    assert_eq!((rel.to_table.as_str(), rel.from_columns[0].as_str(), rel.inferred), ("users", "userId", true));
    let users = graph.tables.iter().find(|t| t.name == "users").unwrap();
    assert!(users.columns.iter().any(|c| c.name == "email" && c.is_unique));
    assert!(users.columns.iter().any(|c| c.name == "_id" && c.is_key));
    exec(s, r#"{"drop": "users"}"#).await;
    exec(s, r#"{"drop": "orders"}"#).await;

    assert_eq!(s.classify(r#"{"dropDatabase": 1}"#.into()), StatementKind::Destructive);
    exec(s, r#"{"drop": "ordal_it"}"#).await;
}

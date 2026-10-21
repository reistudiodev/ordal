//! Needs `DBCLIENT_TEST_REDIS_URL` (Redis 7); skipped otherwise.
//! Uses whatever db index the URL names; point it at a scratch db (e.g. `/15`).

mod common;

use common::{assert_cancels, exec, fixture, run};
use dbclient_core::{NodeKind, Value};

#[tokio::test]
async fn redis_suite() {
    let Some(f) = fixture("REDIS").await else { return };
    let s = &f.session;
    assert!(["Redis", "Valkey"].contains(&s.server_info().await.unwrap().engine.as_str()));
    let db = format!("db{}", s.config().database);

    exec(s, "FLUSHDB").await;
    exec(s, "HSET user:1 name ann age 30").await;
    exec(s, "SET user:2 \"hello world\"").await;
    exec(s, "RPUSH user:1:posts a b c").await;
    exec(s, "SET plain 1 PX 60000").await;

    let (cols, rows, _) = run(s, "HGETALL user:1", 10).await.unwrap();
    assert_eq!(cols[0].name, "field");
    assert_eq!(rows[0].cells, vec![Value::Text { v: "name".into() }, Value::Text { v: "ann".into() }]);
    let (_, rows, _) = run(s, "GET user:2", 10).await.unwrap();
    assert_eq!(rows[0].cells[0], Value::Text { v: "hello world".into() });
    let (cols, rows, _) = run(s, "LRANGE user:1:posts 0 -1", 10).await.unwrap();
    assert_eq!(cols[0].name, "#");
    assert_eq!(rows.len(), 3);

    let dbs = s.list_children(vec![]).await.unwrap();
    assert!(dbs.iter().any(|n| n.name == db && n.kind == NodeKind::Database));
    let top = s.list_children(vec![db.clone()]).await.unwrap();
    assert!(top.iter().any(|n| n.name == "user" && n.kind == NodeKind::KeyPrefix));
    assert!(top.iter().any(|n| n.name == "plain" && n.detail.as_deref() == Some("string")));
    let users = s.list_children(vec![db.clone(), "user".into()]).await.unwrap();
    assert!(users.iter().any(|n| n.name == "1" && n.kind == NodeKind::KeyPrefix));
    assert!(users.iter().any(|n| n.name == "1" && n.kind == NodeKind::Key && n.detail.as_deref() == Some("hash")));

    let info = s.key_info(vec![db.clone(), "plain".into()]).await.unwrap();
    assert_eq!(info.key_type, "string");
    assert!(info.ttl_ms.is_some_and(|t| t > 0));

    // BLPOP blocks server-side; cancel must free it and leave the session usable.
    assert_cancels(s, "BLPOP dbclient:nothing 30").await;
    exec(s, "FLUSHDB").await;
}

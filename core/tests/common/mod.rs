//! Shared helpers for the integration tests.
//!
//! Server engines read their URL from `DBCLIENT_TEST_<ENGINE>_URL` (see
//! `docker-compose.test.yml` and `scripts/test-integration.sh`). When it is
//! unset or the server is unreachable, the test prints a note and passes, so
//! `cargo test` works on machines without Docker.

#![allow(dead_code)]

use std::sync::Arc;
use std::time::Duration;

use dbclient_core::{parse_connection_url, ColumnInfo, ConnectionManager, CoreError, Row, Session};

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

/// The fixture for `DBCLIENT_TEST_<engine>_URL`, or None (test skipped).
pub async fn fixture(engine: &str) -> Option<Fixture> {
    let var = format!("DBCLIENT_TEST_{engine}_URL");
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

//! Streaming and pooling shared by the sqlx-based drivers (Postgres, MySQL, SQLite).
//!
//! User queries are executed as plain `&str` with no bind arguments. sqlx then
//! uses the engine's simple/text protocol, which accepts any statement
//! (multi-statement scripts, DDL, SET...) and sends every value as text, so
//! each driver decodes all types the same way.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;

use futures::{StreamExt, TryStreamExt};
use sqlx::{Column, Database, Either, Executor, Pool, Row as _, TypeInfo};
use tokio_util::sync::CancellationToken;

use super::{or_cancel, Sink};
use crate::error::{CoreError, Result};
use crate::value::{ColumnInfo, Row, ValueKind, Window};

pub(crate) enum StreamEnd {
    Finished { saw_rows: bool },
    Cancelled,
    ReaderGone,
}

/// Streams every row of `sql` into `sink`. Only the first result set that
/// returns rows is shown; later sets with a different shape are skipped.
pub(crate) async fn stream<'c, 'q, DB, E>(
    exec: E,
    sql: &'q str,
    sink: &mut Sink,
    cancel: &CancellationToken,
    kind_of: fn(&str) -> ValueKind,
    decode: impl Fn(&DB::Row, &[ValueKind]) -> Row,
    affected: impl Fn(&DB::QueryResult) -> u64,
) -> Result<StreamEnd>
where
    'c: 'q,
    DB: Database,
    E: Executor<'c, Database = DB>,
{
    let mut rows = exec.fetch_many(sql);
    let mut kinds: Option<Vec<ValueKind>> = None;
    loop {
        let next = match or_cancel(cancel, rows.next()).await {
            Some(next) => next,
            None => return Ok(StreamEnd::Cancelled),
        };
        match next {
            None => break,
            Some(Err(e)) => return Err(e.into()),
            Some(Ok(Either::Left(done))) => sink.add_affected(affected(&done)),
            Some(Ok(Either::Right(row))) => {
                let kinds = match &kinds {
                    Some(k) if k.len() == row.len() => k,
                    Some(_) => continue,
                    None => {
                        let cols = columns(row.columns(), kind_of);
                        let k = cols.iter().map(|c| c.kind).collect();
                        if !sink.columns(cols).await {
                            return Ok(StreamEnd::ReaderGone);
                        }
                        kinds.insert(k)
                    }
                };
                if !sink.push(decode(&row, kinds)).await {
                    return Ok(StreamEnd::ReaderGone);
                }
            }
        }
    }
    Ok(StreamEnd::Finished { saw_rows: kinds.is_some() })
}

/// Runs `sql` (already bounded by a LIMIT) and collects it into a window.
pub(crate) async fn collect<'c, DB, E>(
    exec: E,
    sql: &str,
    kind_of: fn(&str) -> ValueKind,
    decode: impl Fn(&DB::Row, &[ValueKind]) -> Row,
) -> Result<Window>
where
    DB: Database,
    E: Executor<'c, Database = DB>,
{
    let rows: Vec<DB::Row> = exec
        .fetch_many(sql)
        .try_filter_map(|step| async move { Ok(step.right()) })
        .try_collect()
        .await?;
    let Some(first) = rows.first() else {
        return Ok(Window { columns: Vec::new(), rows: Vec::new() });
    };
    let cols = columns(first.columns(), kind_of);
    let kinds: Vec<ValueKind> = cols.iter().map(|c| c.kind).collect();
    Ok(Window { columns: cols, rows: rows.iter().map(|r| decode(r, &kinds)).collect() })
}

/// Column names and types without running the statement (for empty results).
pub(crate) async fn describe<'c, DB, E>(exec: E, sql: &str, kind_of: fn(&str) -> ValueKind) -> Option<Vec<ColumnInfo>>
where
    DB: Database,
    E: Executor<'c, Database = DB>,
{
    let d = exec.describe(sql).await.ok()?;
    Some(columns(d.columns(), kind_of))
}

pub(crate) fn columns<C: Column>(cols: &[C], kind_of: fn(&str) -> ValueKind) -> Vec<ColumnInfo> {
    cols.iter()
        .map(|c| {
            let type_name = c.type_info().name().to_string();
            ColumnInfo { name: c.name().to_string(), kind: kind_of(&type_name), type_name }
        })
        .collect()
}

type PoolFuture<DB> = Pin<Box<dyn Future<Output = Result<Pool<DB>, sqlx::Error>> + Send>>;

/// One pool per database, opened on first use. Postgres needs this because a
/// connection is bound to one database; MySQL uses it so `database` never
/// leaks between tabs through `USE`.
pub(crate) struct Pools<DB: Database> {
    pub(crate) default_db: String,
    open: Box<dyn Fn(String) -> PoolFuture<DB> + Send + Sync>,
    map: tokio::sync::Mutex<HashMap<String, Pool<DB>>>,
}

impl<DB: Database> Pools<DB> {
    /// Opens the default database's pool right away, so bad settings fail early.
    pub(crate) async fn new(
        default_db: String,
        open: impl Fn(String) -> PoolFuture<DB> + Send + Sync + 'static,
    ) -> Result<Self> {
        let first = open(default_db.clone()).await?;
        let mut map = HashMap::new();
        map.insert(default_db.clone(), first);
        Ok(Self { default_db, open: Box::new(open), map: tokio::sync::Mutex::new(map) })
    }

    pub(crate) async fn get(&self, db: Option<&str>) -> Result<Pool<DB>> {
        let db = db.filter(|d| !d.is_empty()).unwrap_or(&self.default_db);
        let mut map = self.map.lock().await;
        if let Some(pool) = map.get(db) {
            return Ok(pool.clone());
        }
        let pool = (self.open)(db.to_string()).await.map_err(CoreError::from)?;
        map.insert(db.to_string(), pool.clone());
        Ok(pool)
    }

    pub(crate) async fn close(&self) {
        let pools: Vec<_> = self.map.lock().await.drain().map(|(_, p)| p).collect();
        for p in pools {
            p.close().await;
        }
    }
}

/// `"name"` with embedded quotes doubled; `q` is `"` or `` ` ``.
pub(crate) fn quote_ident(name: &str, q: char) -> String {
    let mut s = String::with_capacity(name.len() + 2);
    s.push(q);
    for c in name.chars() {
        if c == q {
            s.push(q);
        }
        s.push(c);
    }
    s.push(q);
    s
}

pub(crate) use super::EXACT_COUNT_BELOW;

#[cfg(test)]
mod tests {
    use super::quote_ident;

    #[test]
    fn quotes_identifiers() {
        assert_eq!(quote_ident("a\"b", '"'), "\"a\"\"b\"");
        assert_eq!(quote_ident("we`ird", '`'), "`we``ird`");
    }
}

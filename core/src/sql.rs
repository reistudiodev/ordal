//! A small SQL classifier for safety checks: read-only mode and the
//! "are you sure?" prompt before destructive statements. It is not a parser;
//! it only needs to find each statement's verb and whether a WHERE follows.

/// Ordered from harmless to dangerous, so `max` gives a script's overall kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum StatementKind {
    Read,
    Write,
    Ddl,
    /// DROP, TRUNCATE, DELETE/UPDATE without WHERE, FLUSHALL, dropDatabase...
    Destructive,
}

/// Classifies a SQL script. Multi-statement scripts get their most dangerous kind.
#[uniffi::export]
pub fn classify_statement(sql: String) -> StatementKind {
    classify_sql(&sql)
}

pub(crate) fn classify_sql(sql: &str) -> StatementKind {
    statements(sql)
        .iter()
        .map(|words| classify_words(words))
        .max()
        .unwrap_or(StatementKind::Read)
}

fn classify_words(words: &[String]) -> StatementKind {
    use StatementKind::*;
    let Some(first) = words.first() else { return Read };
    let mut verb_at = 0;
    match first.as_str() {
        // WITH ... AS (...) <verb>: the verb is the first DML word outside parens.
        "WITH" => match words.iter().position(|w| is_dml(w)) {
            Some(i) => verb_at = i,
            None => return Read,
        },
        // EXPLAIN ANALYZE runs the statement; plain EXPLAIN does not.
        "EXPLAIN" => {
            if !words.iter().take(4).any(|w| w == "ANALYZE" || w == "ANALYSE") {
                return Read;
            }
            match words.iter().position(|w| is_dml(w)) {
                Some(i) => verb_at = i,
                None => return Read,
            }
        }
        _ => {}
    }
    let rest = &words[verb_at + 1..];
    match words[verb_at].as_str() {
        "SELECT" | "SHOW" | "DESCRIBE" | "DESC" | "VALUES" | "TABLE" | "BEGIN" | "START"
        | "COMMIT" | "ROLLBACK" | "END" | "SAVEPOINT" | "RELEASE" | "SET" | "RESET" | "USE"
        | "HELP" | "LISTEN" | "UNLISTEN" | "FETCH" | "DECLARE" | "CLOSE" | "PREPARE"
        | "DEALLOCATE" => Read,
        "PRAGMA" => {
            if rest.iter().any(|w| w == "=") {
                Write
            } else {
                Read
            }
        }
        "DELETE" | "UPDATE" => {
            if rest.iter().any(|w| w == "WHERE") {
                Write
            } else {
                Destructive
            }
        }
        "DROP" | "TRUNCATE" => Destructive,
        "CREATE" | "ALTER" | "GRANT" | "REVOKE" | "COMMENT" | "RENAME" => Ddl,
        // INSERT, MERGE, REPLACE, COPY, CALL, VACUUM... and anything unknown.
        _ => Write,
    }
}

fn is_dml(w: &str) -> bool {
    matches!(w, "SELECT" | "INSERT" | "UPDATE" | "DELETE" | "MERGE" | "VALUES" | "TABLE")
}

/// Splits a script into statements of upper-cased top-level words.
/// Comments, string literals, quoted identifiers and anything inside
/// parentheses are skipped. `=` is kept as a word for PRAGMA.
fn statements(sql: &str) -> Vec<Vec<String>> {
    let b = sql.as_bytes();
    let mut out = vec![Vec::new()];
    let mut depth = 0usize;
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        match c {
            b'-' if b.get(i + 1) == Some(&b'-') => {
                i = memchr(b, i, b'\n');
            }
            b'#' => i = memchr(b, i, b'\n'), // MySQL comment
            b'/' if b.get(i + 1) == Some(&b'*') => {
                i = find(b, i + 2, b"*/").map_or(b.len(), |j| j + 2);
            }
            b'\'' | b'"' | b'`' => i = skip_quoted(b, i, c),
            b'$' => match dollar_tag(b, i) {
                Some(tag) => {
                    let body = i + tag.len();
                    i = find(b, body, tag).map_or(b.len(), |j| j + tag.len());
                }
                None => i += 1,
            },
            b'(' => {
                depth += 1;
                i += 1;
            }
            b')' => {
                depth = depth.saturating_sub(1);
                i += 1;
            }
            b';' if depth == 0 => {
                out.push(Vec::new());
                i += 1;
            }
            b'=' => {
                if depth == 0 {
                    out.last_mut().unwrap().push("=".into());
                }
                i += 1;
            }
            c if c.is_ascii_alphabetic() || c == b'_' => {
                let start = i;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_' || b[i] == b'$') {
                    i += 1;
                }
                if depth == 0 {
                    out.last_mut().unwrap().push(sql[start..i].to_ascii_uppercase());
                }
            }
            _ => i += 1,
        }
    }
    out.retain(|s| !s.is_empty());
    out
}

fn memchr(b: &[u8], from: usize, needle: u8) -> usize {
    b[from..].iter().position(|&c| c == needle).map_or(b.len(), |j| from + j)
}

fn find(b: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if from > b.len() {
        return None;
    }
    b[from..].windows(needle.len()).position(|w| w == needle).map(|j| from + j)
}

/// Skips a quoted literal; a doubled quote is an escaped quote.
fn skip_quoted(b: &[u8], start: usize, q: u8) -> usize {
    let mut i = start + 1;
    while i < b.len() {
        if b[i] == b'\\' && q != b'"' {
            i += 2;
            continue;
        }
        if b[i] == q {
            if b.get(i + 1) == Some(&q) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    b.len()
}

/// `$$` or `$tag$` opening a Postgres dollar-quoted string.
fn dollar_tag(b: &[u8], start: usize) -> Option<&[u8]> {
    let mut i = start + 1;
    while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
        i += 1;
    }
    (b.get(i) == Some(&b'$') && !b[start + 1..i].first().is_some_and(u8::is_ascii_digit))
        .then(|| &b[start..=i])
}

#[cfg(test)]
mod tests {
    use super::StatementKind::*;
    use super::*;

    fn k(s: &str) -> StatementKind {
        classify_sql(s)
    }

    #[test]
    fn reads() {
        assert_eq!(k("select * from t"), Read);
        assert_eq!(k("  -- hi\n SELECT 1"), Read);
        assert_eq!(k("show tables"), Read);
        assert_eq!(k("EXPLAIN DELETE FROM t"), Read);
        assert_eq!(k("with x as (delete from t returning *) select 1"), Read);
        assert_eq!(k(""), Read);
        assert_eq!(k("pragma table_info(t)"), Read);
    }

    #[test]
    fn writes() {
        assert_eq!(k("insert into t values (1)"), Write);
        assert_eq!(k("update t set a = 1 where id = 2"), Write);
        assert_eq!(k("delete from t where id in (select id from u)"), Write);
        assert_eq!(k("pragma journal_mode = wal"), Write);
        assert_eq!(k("frobnicate"), Write);
    }

    #[test]
    fn ddl() {
        assert_eq!(k("create table t (a int)"), Ddl);
        assert_eq!(k("ALTER TABLE t ADD COLUMN b int"), Ddl);
    }

    #[test]
    fn destructive() {
        assert_eq!(k("drop table t"), Destructive);
        assert_eq!(k("truncate t"), Destructive);
        assert_eq!(k("delete from t"), Destructive);
        assert_eq!(k("update t set a = 1"), Destructive);
        assert_eq!(k("explain analyze delete from t"), Destructive);
        assert_eq!(k("with x as (select 1) delete from t"), Destructive);
        assert_eq!(k("select 1; drop table t"), Destructive);
    }

    #[test]
    fn where_inside_literals_or_parens_does_not_count() {
        assert_eq!(k("delete from t -- where id = 1"), Destructive);
        assert_eq!(k("update t set note = 'where'"), Destructive);
        assert_eq!(k("update t set a = (select b from u where u.id = 1)"), Destructive);
        assert_eq!(k("update t set a = $$ where $$"), Destructive);
        assert_eq!(k("update t set a = $x$ where $x$"), Destructive);
    }

    #[test]
    fn semicolons_in_strings_do_not_split() {
        assert_eq!(k("select ';drop table t'"), Read);
        assert_eq!(k("select \"a;drop\" from t"), Read);
    }
}

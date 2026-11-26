use lumio_indexing::{Candidate, CandidateKind};
use rusqlite::{Connection, TransactionBehavior, params};
use std::collections::HashSet;
use std::fmt::{Display, Formatter};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_CANDIDATE_PREALLOC: usize = 10_000;

const JOURNAL_SIZE_LIMIT_BYTES: i64 = 4 * 1024 * 1024;

/// Number of rows in the demo seed inserted by `QueryEngine::demo_candidates`.
/// `is_demo_seeded` uses this as an upper bound: anything larger is real data.
/// Keep in sync with `core/engine/src/lib.rs::demo_candidates`.
const DEMO_SEED_ROW_COUNT: i64 = 2;

/// Demo entries use short keys instead of the path-based IDs from discovery.
const DEMO_MARKER_TERMINAL: &str = "app:terminal";
const LEGACY_DEMO_MARKER_SAFARI: &str = "app:safari";
const DEMO_MARKER_VSCODE: &str = "app:vscode";

#[derive(Debug)]
pub enum StorageError {
    Io(std::io::Error),
    Sql(rusqlite::Error),
    Data(String),
}

impl Display for StorageError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            StorageError::Io(err) => write!(f, "io error: {err}"),
            StorageError::Sql(err) => write!(f, "sqlite error: {err}"),
            StorageError::Data(err) => write!(f, "data error: {err}"),
        }
    }
}

impl std::error::Error for StorageError {}

impl From<std::io::Error> for StorageError {
    fn from(value: std::io::Error) -> Self {
        StorageError::Io(value)
    }
}

impl From<rusqlite::Error> for StorageError {
    fn from(value: rusqlite::Error) -> Self {
        StorageError::Sql(value)
    }
}

pub type StorageResult<T> = Result<T, StorageError>;

pub struct SqliteStore {
    conn: Connection,
}

impl SqliteStore {
    /// IMMEDIATE, not the default DEFERRED. Every transaction here writes, and a
    /// deferred one that opens with a read has to upgrade later: SQLite refuses
    /// that with `SQLITE_BUSY` at once, ignoring `busy_timeout`, because waiting
    /// cannot make a stale read snapshot current.
    fn write_tx(&mut self) -> StorageResult<rusqlite::Transaction<'_>> {
        Ok(self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?)
    }

    pub fn open(path: impl AsRef<Path>) -> StorageResult<Self> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let conn = Connection::open(path)?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    pub fn open_in_memory() -> StorageResult<Self> {
        let conn = Connection::open_in_memory()?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    /// Cheap check for "is the candidates table currently just the demo seed?".
    /// Used by `bootstrap_sqlite_scoped` to decide whether to replace demo rows
    /// before streaming real candidates. Older demos included a synthetic
    /// Documents folder that does not count as a real indexed directory.
    ///
    /// Source of truth for the marker ids and row count is
    /// `QueryEngine::demo_candidates` in `core/engine/src/lib.rs`.
    pub fn is_demo_seeded(&self) -> StorageResult<bool> {
        let total: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM candidates
                 WHERE kind IN (?1, ?2, ?3)
                   AND NOT (kind = ?2 AND id = 'folder:docs' AND path = '/Users/user/Documents')",
            [
                CandidateKind::APP_KEY,
                CandidateKind::FOLDER_KEY,
                CandidateKind::ACTION_KEY,
            ],
            |row| row.get(0),
        )?;
        // Anything larger than the demo seed is definitely real data.
        if total == 0 || total > DEMO_SEED_ROW_COUNT {
            return Ok(false);
        }
        Ok(self.has_candidate(DEMO_MARKER_VSCODE)?
            && (self.has_candidate(DEMO_MARKER_TERMINAL)?
                || self.has_candidate(LEGACY_DEMO_MARKER_SAFARI)?))
    }

    fn has_candidate(&self, id: &str) -> StorageResult<bool> {
        let hit: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM candidates WHERE id = ?1 AND kind = ?2",
            [id, CandidateKind::APP_KEY],
            |row| row.get(0),
        )?;
        Ok(hit > 0)
    }

    pub fn load_candidates(&self, limit: Option<usize>) -> StorageResult<Vec<Candidate>> {
        // Older databases can contain file rows. Filter in SQLite so those rows
        // never enter the index or count against the requested limit.
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, title, subtitle, path, use_count, last_used_at_unix_s, icon
             FROM candidates
             WHERE kind IN (?1, ?2, ?3)
             ORDER BY title ASC LIMIT ?4",
        )?;
        let mut rows = stmt.query(params![
            CandidateKind::APP_KEY,
            CandidateKind::FOLDER_KEY,
            CandidateKind::ACTION_KEY,
            limit.map_or(-1, |max| max as i64),
        ])?;

        let mut out = match limit {
            Some(max) => Vec::with_capacity(max.min(MAX_CANDIDATE_PREALLOC)),
            None => Vec::new(),
        };
        while let Some(row) = rows.next()? {
            let kind_raw: String = row.get(1)?;
            let use_count_raw: i64 = row.get(5)?;
            out.push(Candidate {
                id: row.get::<_, String>(0)?.into_boxed_str(),
                kind: parse_kind(&kind_raw)?,
                title: row.get::<_, String>(2)?.into_boxed_str(),
                subtitle: row.get::<_, Option<String>>(3)?.map(String::into_boxed_str),
                path: row.get::<_, String>(4)?.into_boxed_str(),
                use_count: to_use_count(use_count_raw)?,
                last_used_at_unix_s: row.get(6)?,
                icon: row.get::<_, Option<String>>(7)?.map(String::into_boxed_str),
            });
        }

        Ok(out)
    }

    pub fn upsert_candidates(&mut self, candidates: &[Candidate]) -> StorageResult<()> {
        self.upsert_candidates_indexed(candidates, Some(current_unix_s()?))
    }

    pub fn upsert_candidates_indexed(
        &mut self,
        candidates: &[Candidate],
        indexed_at_unix_s: Option<i64>,
    ) -> StorageResult<()> {
        let tx = self.write_tx()?;
        {
            let mut stmt = tx.prepare(
                // Skip unchanged rows and let the seen-set sweep handle pruning.
                // Usage fields are maintained separately from discovery metadata.
                "INSERT INTO candidates (id, kind, title, subtitle, path, use_count, last_used_at_unix_s, indexed_at_unix_s, icon)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(id) DO UPDATE SET
                   kind = excluded.kind,
                   title = excluded.title,
                   subtitle = excluded.subtitle,
                   path = excluded.path,
                   indexed_at_unix_s = excluded.indexed_at_unix_s,
                   icon = excluded.icon
                 WHERE candidates.kind <> excluded.kind
                    OR candidates.title <> excluded.title
                    OR candidates.subtitle IS NOT excluded.subtitle
                    OR candidates.path <> excluded.path
                    OR candidates.icon IS NOT excluded.icon",
            )?;

            for candidate in candidates {
                let use_count = from_use_count(candidate.use_count)?;
                stmt.execute(params![
                    candidate.id.as_ref(),
                    kind_key(&candidate.kind),
                    candidate.title.as_ref(),
                    candidate.subtitle.as_deref(),
                    candidate.path.as_ref(),
                    use_count,
                    candidate.last_used_at_unix_s,
                    indexed_at_unix_s,
                    candidate.icon.as_deref(),
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn replace_candidates(&mut self, candidates: &[Candidate]) -> StorageResult<()> {
        let tx = self.write_tx()?;
        tx.execute("DELETE FROM usage_events", [])?;
        tx.execute("DELETE FROM candidates", [])?;

        {
            let mut stmt = tx.prepare(
                "INSERT INTO candidates (id, kind, title, subtitle, path, use_count, last_used_at_unix_s, indexed_at_unix_s, icon)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;

            for candidate in candidates {
                let use_count = from_use_count(candidate.use_count)?;
                stmt.execute(params![
                    candidate.id.as_ref(),
                    kind_key(&candidate.kind),
                    candidate.title.as_ref(),
                    candidate.subtitle.as_deref(),
                    candidate.path.as_ref(),
                    use_count,
                    candidate.last_used_at_unix_s,
                    None::<i64>,
                    candidate.icon.as_deref(),
                ])?;
            }
        }

        tx.commit()?;
        Ok(())
    }

    pub fn record_usage_event(&self, candidate_id: &str, action: &str) -> StorageResult<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|err| StorageError::Data(format!("system time error: {err}")))?
            .as_secs() as i64;

        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO usage_events(candidate_id, action, used_at_unix_s) VALUES (?1, ?2, ?3)",
            params![candidate_id, action, now],
        )?;
        tx.execute(
            "UPDATE candidates SET use_count = use_count + 1, last_used_at_unix_s = ?2 WHERE id = ?1",
            params![candidate_id, now],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn delete_stale_candidates(&mut self, older_than_unix_s: i64) -> StorageResult<usize> {
        let tx = self.write_tx()?;
        tx.execute(
            "DELETE FROM usage_events
             WHERE candidate_id IN (
               SELECT id FROM candidates
               WHERE indexed_at_unix_s IS NULL OR indexed_at_unix_s < ?1
             )",
            params![older_than_unix_s],
        )?;
        let removed = tx.execute(
            "DELETE FROM candidates
             WHERE indexed_at_unix_s IS NULL OR indexed_at_unix_s < ?1",
            params![older_than_unix_s],
        )?;
        tx.commit()?;
        Ok(removed)
    }

    /// Seen-set pruning, the counterpart to the change-detecting upsert
    /// (see specs/indexing-scale.md). Because the upsert no longer bumps
    /// `indexed_at` on unchanged rows, "was this seen in the latest scan?" can't
    /// be inferred from `indexed_at` anymore - we delete rows in scope that are
    /// NOT in `seen_ids`. The `indexed_at < older_than_unix_s` guard preserves the
    /// `i64::MAX` pinned/seeded rows (e.g. UWP), exactly like `delete_stale_*`.
    /// `prefixes` empty = whole table (ALL-scope refresh); otherwise restrict to
    /// rows whose id starts with one of the prefixes (scoped refresh).
    ///
    /// `seen_ids` is staged in an in-memory temp table (PRAGMA temp_store=MEMORY),
    /// so this adds no persistent writes beyond the rows it actually deletes.
    pub fn delete_unseen_candidates(
        &mut self,
        seen_ids: &HashSet<Box<str>>,
        older_than_unix_s: i64,
        prefixes: &[&str],
    ) -> StorageResult<usize> {
        let like_clause = if prefixes.is_empty() {
            String::new()
        } else {
            let ors = (0..prefixes.len())
                .map(|i| format!("id LIKE ?{} ESCAPE '\\'", i + 2))
                .collect::<Vec<_>>()
                .join(" OR ");
            format!(" AND ({ors})")
        };
        let escaped: Vec<String> = prefixes
            .iter()
            .map(|p| format!("{}%", like_escape(p)))
            .collect();

        let tx = self.write_tx()?;
        tx.execute_batch(
            "CREATE TEMP TABLE IF NOT EXISTS _seen_ids (id TEXT PRIMARY KEY);
             DELETE FROM _seen_ids;",
        )?;
        {
            let mut stmt = tx.prepare("INSERT OR IGNORE INTO _seen_ids (id) VALUES (?1)")?;
            for id in seen_ids {
                stmt.execute(params![id.as_ref()])?;
            }
        }

        let mut bindings: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(1 + escaped.len());
        bindings.push(&older_than_unix_s);
        for s in &escaped {
            bindings.push(s);
        }

        let where_unseen = format!(
            "(indexed_at_unix_s IS NULL OR indexed_at_unix_s < ?1)
             AND id NOT IN (SELECT id FROM _seen_ids){like_clause}"
        );

        tx.execute(
            &format!(
                "DELETE FROM usage_events WHERE candidate_id IN (
                   SELECT id FROM candidates WHERE {where_unseen}
                 )"
            ),
            bindings.as_slice(),
        )?;
        let removed = tx.execute(
            &format!("DELETE FROM candidates WHERE {where_unseen}"),
            bindings.as_slice(),
        )?;
        tx.commit()?;
        Ok(removed)
    }

    /// Scoped variant of `delete_stale_candidates`: prunes only rows whose id begins
    /// with one of `prefixes`. Used by partial reindex paths that re-walk a subset
    /// of sources (e.g. apps-only) and must not prune candidates from sources that
    /// were not part of this run.
    pub fn delete_stale_candidates_with_prefixes(
        &mut self,
        older_than_unix_s: i64,
        prefixes: &[&str],
    ) -> StorageResult<usize> {
        if prefixes.is_empty() {
            return Ok(0);
        }
        let escaped: Vec<String> = prefixes
            .iter()
            .map(|p| format!("{}%", like_escape(p)))
            .collect();
        let like_clause = (0..escaped.len())
            .map(|i| format!("id LIKE ?{} ESCAPE '\\'", i + 2))
            .collect::<Vec<_>>()
            .join(" OR ");

        let tx = self.write_tx()?;

        let mut bindings: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(1 + escaped.len());
        bindings.push(&older_than_unix_s);
        for s in &escaped {
            bindings.push(s);
        }

        let del_usage_sql = format!(
            "DELETE FROM usage_events
             WHERE candidate_id IN (
               SELECT id FROM candidates
               WHERE (indexed_at_unix_s IS NULL OR indexed_at_unix_s < ?1)
                 AND ({like_clause})
             )"
        );
        tx.execute(&del_usage_sql, bindings.as_slice())?;

        let del_cand_sql = format!(
            "DELETE FROM candidates
             WHERE (indexed_at_unix_s IS NULL OR indexed_at_unix_s < ?1)
               AND ({like_clause})"
        );
        let removed = tx.execute(&del_cand_sql, bindings.as_slice())?;
        tx.commit()?;
        Ok(removed)
    }

    /// Deletes every candidate whose `id` starts with `prefix` and is NOT in `keep_ids`,
    /// along with its usage_events rows. Returned value is the number of candidate rows
    /// removed. Used by the UWP seed path (bridge/ffi/src/seed_api.rs) to age out apps
    /// that disappeared from `shell:AppsFolder` between runs - those rows can't be
    /// pruned by `delete_stale_candidates` because they're written with
    /// `indexed_at_unix_s = i64::MAX` to survive the regular index-refresh sweep.
    pub fn delete_candidates_by_prefix_except(
        &mut self,
        prefix: &str,
        keep_ids: &HashSet<&str>,
    ) -> StorageResult<usize> {
        let tx = self.write_tx()?;
        let like_pattern = format!("{}%", like_escape(prefix));

        let stale_ids: Vec<String> = {
            let mut stmt = tx.prepare("SELECT id FROM candidates WHERE id LIKE ?1 ESCAPE '\\'")?;
            let rows = stmt.query_map(params![like_pattern], |row| row.get::<_, String>(0))?;
            let mut out = Vec::new();
            for row in rows {
                let id = row?;
                if !keep_ids.contains(id.as_str()) {
                    out.push(id);
                }
            }
            out
        };

        for id in &stale_ids {
            tx.execute(
                "DELETE FROM usage_events WHERE candidate_id = ?1",
                params![id],
            )?;
            tx.execute("DELETE FROM candidates WHERE id = ?1", params![id])?;
        }
        tx.commit()?;
        Ok(stale_ids.len())
    }

    pub fn prune_usage_events_older_than(&mut self, cutoff_unix_s: i64) -> StorageResult<usize> {
        let removed = self.conn.execute(
            "DELETE FROM usage_events WHERE used_at_unix_s < ?1",
            params![cutoff_unix_s],
        )?;
        Ok(removed)
    }

    pub fn prune_usage_events_to_max(&mut self, max_rows: usize) -> StorageResult<usize> {
        let total: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))?;
        let total = total.max(0) as usize;
        if total <= max_rows {
            return Ok(0);
        }

        let overflow = total - max_rows;
        let removed = self.conn.execute(
            "DELETE FROM usage_events
             WHERE id IN (
               SELECT id FROM usage_events ORDER BY used_at_unix_s ASC, id ASC LIMIT ?1
             )",
            params![overflow as i64],
        )?;
        Ok(removed)
    }

    fn migrate(&self) -> StorageResult<()> {
        self.conn
            .pragma_update(None, "journal_size_limit", JOURNAL_SIZE_LIMIT_BYTES)?;
        self.conn.execute_batch(
            // No `busy_timeout`: rusqlite already sets 5s on every connection
            // it opens, before any of this runs.
            "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             -- Keep the seen-id temp table used by delete_unseen_candidates in RAM.
             PRAGMA temp_store = MEMORY;

             CREATE TABLE IF NOT EXISTS candidates (
                 id TEXT PRIMARY KEY,
                 kind TEXT NOT NULL,
                 title TEXT NOT NULL,
                 subtitle TEXT,
                 path TEXT NOT NULL,
                 use_count INTEGER NOT NULL DEFAULT 0,
                 last_used_at_unix_s INTEGER,
                 indexed_at_unix_s INTEGER
              );

             CREATE INDEX IF NOT EXISTS idx_candidates_title ON candidates(title);
             CREATE INDEX IF NOT EXISTS idx_candidates_kind ON candidates(kind);

             CREATE TABLE IF NOT EXISTS usage_events (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 candidate_id TEXT NOT NULL,
                 action TEXT NOT NULL,
                 used_at_unix_s INTEGER NOT NULL,
                 FOREIGN KEY(candidate_id) REFERENCES candidates(id)
             );

              CREATE TABLE IF NOT EXISTS index_state (
                  source TEXT PRIMARY KEY,
                  last_indexed_at_unix_s INTEGER NOT NULL
              );",
        )?;

        ensure_column_exists(&self.conn, "candidates", "indexed_at_unix_s", "INTEGER")?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_candidates_indexed_at ON candidates(indexed_at_unix_s)",
            [],
        )?;

        // What a declared source row asked to be drawn as. Only source rows set
        // it, so it is NULL for almost every row. Additive on existing DBs.
        ensure_column_exists(&self.conn, "candidates", "icon", "TEXT")?;

        Ok(())
    }
}

fn ensure_column_exists(
    conn: &Connection,
    table: &str,
    column: &str,
    column_type: &str,
) -> StorageResult<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            return Ok(());
        }
    }

    conn.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {column_type}"),
        [],
    )?;
    Ok(())
}

/// Escapes LIKE metacharacters so a typed `%` or `_` is literal. Every LIKE
/// query goes through this; three hand-written copies had forgotten `_`.
fn like_escape(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn current_unix_s() -> StorageResult<i64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| StorageError::Data(format!("system time error: {err}")))
        .map(|d| d.as_secs() as i64)
}

fn to_use_count(value: i64) -> StorageResult<u64> {
    u64::try_from(value)
        .map_err(|_| StorageError::Data(format!("invalid use_count in sqlite: {value}")))
}

fn from_use_count(value: u64) -> StorageResult<i64> {
    i64::try_from(value)
        .map_err(|_| StorageError::Data(format!("use_count overflow for sqlite: {value}")))
}

fn kind_key(kind: &CandidateKind) -> &'static str {
    kind.as_str()
}

fn parse_kind(value: &str) -> StorageResult<CandidateKind> {
    CandidateKind::from_key(value)
        .ok_or_else(|| StorageError::Data(format!("unknown candidate kind: {value}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(id: &str, title: &str, path: &str) -> Candidate {
        Candidate {
            id: id.into(),
            kind: CandidateKind::App,
            title: title.into(),
            subtitle: Some("test subtitle".into()),
            path: path.into(),
            ..Default::default()
        }
    }

    #[test]
    fn open_in_memory_runs_migrations() {
        let store = SqliteStore::open_in_memory().expect("open sqlite in memory");

        let mut stmt = store
            .conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?1")
            .expect("prepare sqlite_master query");

        for name in ["candidates", "usage_events", "index_state"] {
            let mut rows = stmt.query([name]).expect("query table name");
            assert!(rows.next().expect("fetch table row").is_some());
        }
        for name in ["settings", "url_history"] {
            let mut rows = stmt.query([name]).expect("query obsolete table name");
            assert!(rows.next().expect("fetch table row").is_none());
        }
    }

    #[test]
    fn load_candidates_skips_legacy_files_before_limit() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        store
            .conn
            .execute_batch(
                "INSERT INTO candidates (id, kind, title, path) VALUES
                 ('file:legacy', 'file', 'A document', '/Users/demo/document.txt'),
                 ('folder:legacy', 'folder', 'Projects', '/Users/demo/projects');",
            )
            .expect("seed old index rows");
        store
            .upsert_candidates(&[
                candidate("app:test", "Test App", "/Applications/Test.app"),
                Candidate::new(
                    "src:test:action",
                    CandidateKind::Action,
                    "Utility",
                    "utility",
                ),
            ])
            .expect("add current rows");

        let limited = store.load_candidates(Some(1)).expect("load one result");
        assert_eq!(limited.len(), 1);
        assert_eq!(limited[0].id.as_ref(), "folder:legacy");
        assert_eq!(limited[0].kind, CandidateKind::Folder);
        let all = store.load_candidates(None).expect("load all results");
        assert_eq!(all.len(), 3);
        assert_eq!(all[1].id.as_ref(), "app:test");
        assert_eq!(all[2].kind, CandidateKind::Action);
        let legacy_count: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM candidates WHERE kind = 'file'",
                [],
                |row| row.get(0),
            )
            .expect("count legacy rows");
        assert_eq!(legacy_count, 1);
    }

    #[test]
    fn upsert_and_load_candidates_round_trip() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let first = candidate("app:test", "Test App", "/Applications/Test.app");

        store.upsert_candidates(&[first]).expect("insert candidate");

        let loaded = store.load_candidates(None).expect("load candidates");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id.as_ref(), "app:test");
        assert_eq!(loaded[0].title.as_ref(), "Test App");
        assert_eq!(loaded[0].path.as_ref(), "/Applications/Test.app");
        assert_eq!(loaded[0].use_count, 0);
        assert_eq!(loaded[0].last_used_at_unix_s, None);
    }

    #[test]
    fn a_declared_row_icon_survives_the_index() {
        // Source rows are persisted like every other candidate and re-read from
        // here on the next launch. An icon that did not round-trip would show
        // once, at index time, and be gone after a restart.
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let mut row = candidate("src:history:https://github.com", "GitHub", "");
        row.icon = Some("/tmp/fav/github.com.png".into());
        store.upsert_candidates(&[row]).expect("insert candidate");

        let loaded = store.load_candidates(None).expect("load candidates");
        assert_eq!(loaded[0].icon.as_deref(), Some("/tmp/fav/github.com.png"));

        // A re-index that changes only the icon must still write: it is in the
        // change-detection list, so a moved favicon is not stale forever.
        let mut moved = candidate("src:history:https://github.com", "GitHub", "");
        moved.icon = Some("/tmp/fav2/github.com.png".into());
        store
            .upsert_candidates(&[moved])
            .expect("update candidate icon");
        let after = store.load_candidates(None).expect("reload candidates");
        assert_eq!(after[0].icon.as_deref(), Some("/tmp/fav2/github.com.png"));
    }

    #[test]
    fn usage_recording_and_upsert_preserves_usage_metrics() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let first = candidate("app:test", "Test App", "/Applications/Test.app");

        store.upsert_candidates(&[first]).expect("insert candidate");

        store
            .record_usage_event("app:test", "open_app")
            .expect("record usage event");

        let after_usage = store
            .load_candidates(None)
            .expect("load candidates after usage");
        assert_eq!(after_usage[0].use_count, 1);
        assert!(after_usage[0].last_used_at_unix_s.is_some());

        let updated = Candidate {
            id: "app:test".into(),
            kind: CandidateKind::App,
            title: "Renamed App".into(),
            subtitle: Some("updated subtitle".into()),
            path: "/Applications/Renamed.app".into(),
            ..Default::default()
        };

        store
            .upsert_candidates(&[updated])
            .expect("upsert updated candidate");

        let final_rows = store.load_candidates(None).expect("load final candidates");
        assert_eq!(final_rows.len(), 1);
        assert_eq!(final_rows[0].title.as_ref(), "Renamed App");
        assert_eq!(final_rows[0].path.as_ref(), "/Applications/Renamed.app");
        assert_eq!(final_rows[0].use_count, 1);
        assert!(final_rows[0].last_used_at_unix_s.is_some());

        let usage_count: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))
            .expect("count usage events");
        assert_eq!(usage_count, 1);
    }

    #[test]
    fn delete_stale_candidates_removes_older_rows() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old = candidate("app:old", "Old", "/Applications/Old.app");
        let fresh = candidate("app:fresh", "Fresh", "/Applications/Fresh.app");

        store
            .upsert_candidates_indexed(&[old], Some(100))
            .expect("insert old");
        store
            .upsert_candidates_indexed(&[fresh], Some(200))
            .expect("insert fresh");

        let removed = store
            .delete_stale_candidates(150)
            .expect("delete stale candidates");
        assert_eq!(removed, 1);

        let loaded = store.load_candidates(None).expect("load candidates");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id.as_ref(), "app:fresh");
    }

    #[test]
    fn delete_stale_candidates_also_cleans_null_indexed_rows() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old_style = candidate("app:null", "Null Indexed", "/Applications/Null.app");
        store
            .upsert_candidates_indexed(&[old_style], None)
            .expect("insert null-indexed row");

        let removed = store
            .delete_stale_candidates(1)
            .expect("delete stale including null");
        assert_eq!(removed, 1);

        let loaded = store.load_candidates(None).expect("load candidates");
        assert!(loaded.is_empty());
    }

    #[test]
    fn upsert_skips_write_when_row_unchanged() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let c = candidate("app:a", "App A", "/Applications/A.app");
        store
            .upsert_candidates_indexed(std::slice::from_ref(&c), Some(100))
            .expect("first insert");
        // Re-upsert identical content on a later run: the WHERE guard should skip
        // the UPDATE, so indexed_at stays at the original value (no rewrite).
        store
            .upsert_candidates_indexed(&[c], Some(200))
            .expect("no-op upsert");
        let indexed: i64 = store
            .conn
            .query_row(
                "SELECT indexed_at_unix_s FROM candidates WHERE id = 'app:a'",
                [],
                |row| row.get(0),
            )
            .expect("read indexed_at");
        assert_eq!(indexed, 100, "unchanged row must not be rewritten");
    }

    #[test]
    fn upsert_writes_when_content_changes() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        store
            .upsert_candidates_indexed(
                &[candidate("app:a", "App A", "/Applications/A.app")],
                Some(100),
            )
            .expect("first insert");
        store
            .upsert_candidates_indexed(
                &[candidate("app:a", "Renamed App", "/Applications/A.app")],
                Some(200),
            )
            .expect("changed upsert");
        let indexed: i64 = store
            .conn
            .query_row(
                "SELECT indexed_at_unix_s FROM candidates WHERE id = 'app:a'",
                [],
                |row| row.get(0),
            )
            .expect("read indexed_at");
        assert_eq!(indexed, 200, "changed row must be rewritten");
        let loaded = store.load_candidates(None).expect("load");
        assert_eq!(loaded[0].title.as_ref(), "Renamed App");
    }

    #[test]
    fn delete_unseen_removes_unseen_keeps_seen_and_pinned() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        store
            .upsert_candidates_indexed(
                &[
                    candidate("app:a", "A", "/Applications/A.app"),
                    candidate("app:b", "B", "/Applications/B.app"),
                ],
                Some(100),
            )
            .expect("insert apps");
        // Pinned/seeded row uses i64::MAX indexed_at to survive sweeps.
        store
            .upsert_candidates_indexed(&[candidate("uwp:pinned", "Pinned", "/p")], Some(i64::MAX))
            .expect("insert pinned");

        // The latest scan only saw app:a.
        let mut seen: HashSet<Box<str>> = HashSet::new();
        seen.insert("app:a".into());
        let removed = store
            .delete_unseen_candidates(&seen, 200, &[])
            .expect("prune unseen");
        assert_eq!(removed, 1);

        let ids: Vec<String> = store
            .load_candidates(None)
            .expect("load")
            .iter()
            .map(|c| c.id.to_string())
            .collect();
        assert!(ids.contains(&"app:a".to_string()), "seen row kept");
        assert!(ids.contains(&"uwp:pinned".to_string()), "pinned row kept");
        assert!(!ids.contains(&"app:b".to_string()), "unseen row removed");
    }

    #[test]
    fn delete_unseen_respects_prefixes() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        store
            .upsert_candidates_indexed(
                &[
                    candidate("app:x", "X", "/x"),
                    candidate("setting:y", "Y", "settings://y"),
                ],
                Some(100),
            )
            .expect("insert");
        // Scoped (apps-only) refresh saw nothing: only app:* may be pruned.
        let seen: HashSet<Box<str>> = HashSet::new();
        let removed = store
            .delete_unseen_candidates(&seen, 200, &["app:"])
            .expect("scoped prune");
        assert_eq!(removed, 1);
        let ids: Vec<String> = store
            .load_candidates(None)
            .expect("load")
            .iter()
            .map(|c| c.id.to_string())
            .collect();
        assert!(
            ids.contains(&"setting:y".to_string()),
            "out-of-scope row kept"
        );
        assert!(
            !ids.contains(&"app:x".to_string()),
            "in-scope unseen removed"
        );
    }

    #[test]
    fn is_demo_seeded_recognizes_demo_rows() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let vscode = candidate("app:vscode", "VS Code", "/Applications/Code.app");
        let terminal = candidate(
            "app:terminal",
            "Terminal",
            "/System/Applications/Utilities/Terminal.app",
        );
        store
            .upsert_candidates_indexed(&[terminal, vscode.clone()], Some(100))
            .expect("seed demo rows");

        assert!(store.is_demo_seeded().expect("query"));

        let safari = candidate("app:safari", "Safari", "/Applications/Safari.app");
        store
            .replace_candidates(&[safari, vscode])
            .expect("seed legacy demo apps");
        store
            .conn
            .execute_batch(
                "INSERT INTO candidates (id, kind, title, path) VALUES
                 ('file:notes', 'file', 'Notes.txt', '/Users/user/Documents/Notes.txt'),
                 ('folder:docs', 'folder', 'Documents', '/Users/user/Documents');",
            )
            .expect("seed legacy demo rows");
        assert!(store.is_demo_seeded().expect("query legacy demo"));

        let projects = Candidate::new(
            "folder:/Users/demo/Projects",
            CandidateKind::Folder,
            "Projects",
            "/Users/demo/Projects",
        );
        store.upsert_candidates(&[projects]).expect("add folder");
        assert!(!store.is_demo_seeded().expect("query mixed index"));
    }

    #[test]
    fn is_demo_seeded_returns_false_for_empty_table() {
        let store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        assert!(!store.is_demo_seeded().expect("query"));
    }

    #[test]
    fn is_demo_seeded_returns_false_when_real_data_present() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        // > 2 rows means we're past the demo seed regardless of contents.
        let rows: Vec<Candidate> = (0..10)
            .map(|i| {
                candidate(
                    &format!("app:user-app-{i}"),
                    &format!("App {i}"),
                    &format!("/Applications/App{i}.app"),
                )
            })
            .collect();
        store
            .upsert_candidates_indexed(&rows, Some(100))
            .expect("seed");
        assert!(!store.is_demo_seeded().expect("query"));
    }

    #[test]
    fn is_demo_seeded_returns_false_for_partial_demo_match() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        // Only one demo marker - not the full seed.
        let only_safari = candidate("app:safari", "Safari", "/Applications/Safari.app");
        store
            .upsert_candidates_indexed(&[only_safari], Some(100))
            .expect("seed");
        assert!(!store.is_demo_seeded().expect("query"));
    }

    #[test]
    fn delete_stale_candidates_with_prefixes_is_noop_on_empty_prefix_list() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old = candidate("app:old", "Old", "/Applications/Old.app");
        store
            .upsert_candidates_indexed(&[old], Some(100))
            .expect("insert");

        let removed = store
            .delete_stale_candidates_with_prefixes(200, &[])
            .expect("noop");
        assert_eq!(removed, 0);
        let loaded = store.load_candidates(None).expect("load");
        assert_eq!(loaded.len(), 1, "row must be preserved");
    }

    #[test]
    fn delete_stale_candidates_with_prefixes_accepts_multiple_prefixes() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old_app = candidate("app:old", "Old App", "/Applications/Old.app");
        let old_source = candidate("src:old", "Old Source", "/Applications/Source.app");
        let old_setting = candidate("setting:old", "Old Setting", "settings://old");

        store
            .upsert_candidates_indexed(&[old_app, old_source, old_setting], Some(100))
            .expect("seed");

        // Sweep apps and externally declared source rows.
        let removed = store
            .delete_stale_candidates_with_prefixes(200, &["app:", "src:"])
            .expect("sweep");
        assert_eq!(removed, 2);

        let ids: Vec<String> = store
            .load_candidates(None)
            .expect("load")
            .into_iter()
            .map(|c| c.id.as_ref().to_string())
            .collect();
        assert_eq!(ids, vec!["setting:old"]);
    }

    #[test]
    fn delete_stale_candidates_with_prefixes_purges_matching_usage_events() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old_app = candidate("app:old", "Old App", "/Applications/Old.app");
        let old_setting = candidate("setting:old", "Old Setting", "settings://old");
        store
            .upsert_candidates_indexed(&[old_app.clone(), old_setting.clone()], Some(100))
            .expect("seed");
        store
            .record_usage_event(old_app.id.as_ref(), "open_app")
            .expect("record app usage");
        store
            .record_usage_event(old_setting.id.as_ref(), "open_app")
            .expect("record setting usage");

        let removed = store
            .delete_stale_candidates_with_prefixes(200, &["app:"])
            .expect("sweep apps");
        assert_eq!(removed, 1);

        // app:old's usage_events row must be gone; setting:old's must remain.
        let app_usage: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE candidate_id = ?1",
                params!["app:old"],
                |row| row.get(0),
            )
            .expect("count app usage");
        assert_eq!(app_usage, 0);
        let setting_usage: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE candidate_id = ?1",
                params!["setting:old"],
                |row| row.get(0),
            )
            .expect("count setting usage");
        assert_eq!(setting_usage, 1);
    }

    #[test]
    fn delete_stale_candidates_with_prefixes_only_touches_matching_kinds() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let old_app = candidate("app:old", "Old App", "/Applications/Old.app");
        let old_setting = candidate("setting:old", "Old Setting", "settings://old");
        let fresh_app = candidate("app:fresh", "Fresh App", "/Applications/Fresh.app");
        let fresh_setting = candidate("setting:fresh", "Fresh Setting", "settings://fresh");

        store
            .upsert_candidates_indexed(&[old_app, old_setting], Some(100))
            .expect("insert old rows");
        store
            .upsert_candidates_indexed(&[fresh_app, fresh_setting], Some(200))
            .expect("insert fresh rows");

        let removed = store
            .delete_stale_candidates_with_prefixes(150, &["app:"])
            .expect("prune stale apps");
        assert_eq!(removed, 1);

        let ids: Vec<String> = store
            .load_candidates(None)
            .expect("load")
            .into_iter()
            .map(|c| c.id.as_ref().to_string())
            .collect();
        assert!(!ids.contains(&"app:old".to_string()));
        assert!(ids.contains(&"app:fresh".to_string()));
        // setting:old is older than the cutoff but must be untouched because we
        // restricted the sweep to the `app:` prefix.
        assert!(ids.contains(&"setting:old".to_string()));
        assert!(ids.contains(&"setting:fresh".to_string()));
    }

    #[test]
    fn delete_candidates_by_prefix_except_removes_vanished_rows_and_preserves_kept() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let kept = candidate(
            "app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App",
            "Terminal",
            "shell:AppsFolder\\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App",
        );
        let stale = candidate(
            "app:uwp:Old.PackageThatGotUninstalled_abc!App",
            "Old App",
            "shell:AppsFolder\\Old.PackageThatGotUninstalled_abc!App",
        );
        let win32 = candidate(
            "app:edge_c:/programdata/microsoft/windows/start menu/programs/microsoft edge.lnk",
            "Microsoft Edge",
            "C:/ProgramData/Microsoft/Windows/Start Menu/Programs/Microsoft Edge.lnk",
        );

        store
            .upsert_candidates_indexed(&[kept, stale.clone(), win32], Some(i64::MAX))
            .expect("seed candidates");

        // Record usage on the stale row so we can verify usage_events are also removed.
        store
            .record_usage_event(stale.id.as_ref(), "open_app")
            .expect("record stale usage");

        let mut keep_set = HashSet::new();
        keep_set.insert("app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App");

        let removed = store
            .delete_candidates_by_prefix_except("app:uwp:", &keep_set)
            .expect("prune");
        assert_eq!(removed, 1);

        let loaded = store.load_candidates(None).expect("load");
        let ids: Vec<&str> = loaded.iter().map(|c| c.id.as_ref()).collect();
        assert!(ids.contains(&"app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"));
        assert!(!ids.contains(&"app:uwp:Old.PackageThatGotUninstalled_abc!App"));
        // The non-uwp `app:` row must be untouched even though it shares the broader
        // `app:` prefix - only `app:uwp:` rows are eligible for this sweep.
        assert!(ids.contains(
            &"app:edge_c:/programdata/microsoft/windows/start menu/programs/microsoft edge.lnk"
        ));

        // usage_events for the deleted candidate should also be cleaned up.
        let usage_count: i64 = store
            .conn
            .query_row(
                "SELECT COUNT(*) FROM usage_events WHERE candidate_id = ?1",
                params![stale.id.as_ref()],
                |row| row.get(0),
            )
            .expect("count usage events");
        assert_eq!(usage_count, 0);
    }

    /// Passes on rusqlite's own 5s busy timeout, so it guards against that being
    /// taken away rather than proving anything the store does. The WAL
    /// conversion in `migrate` is the exclusive-lock step it blocks on.
    #[test]
    fn an_open_waits_for_a_database_someone_else_is_holding() {
        /// Long enough to be blocked when released, far under the 5s timeout.
        const HOLD: std::time::Duration = std::time::Duration::from_millis(200);

        let dir = std::env::temp_dir().join(format!("lumio-store-busy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("contended.db");
        let _ = std::fs::remove_file(&path);

        // A plain connection, so the file exists and is NOT yet in WAL.
        let blocker = Connection::open(&path).expect("blocker connection");
        blocker
            .execute_batch("BEGIN EXCLUSIVE; CREATE TABLE probe(x);")
            .expect("take the lock");

        let opening = {
            let path = path.clone();
            std::thread::spawn(move || SqliteStore::open(&path).is_ok())
        };

        std::thread::sleep(HOLD);
        blocker.execute_batch("COMMIT").expect("release the lock");

        assert!(
            opening.join().expect("the opening thread"),
            "an open must wait for the other writer rather than fail"
        );

        drop(blocker);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delete_candidates_by_prefix_except_is_noop_when_all_kept() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let cand = candidate(
            "app:uwp:Microsoft.Notepad_8wekyb3d8bbwe!App",
            "Notepad",
            "shell:AppsFolder\\Microsoft.Notepad_8wekyb3d8bbwe!App",
        );
        store
            .upsert_candidates_indexed(&[cand], Some(i64::MAX))
            .expect("seed");

        let mut keep_set = HashSet::new();
        keep_set.insert("app:uwp:Microsoft.Notepad_8wekyb3d8bbwe!App");

        let removed = store
            .delete_candidates_by_prefix_except("app:uwp:", &keep_set)
            .expect("prune");
        assert_eq!(removed, 0);
    }

    #[test]
    fn prune_usage_events_applies_age_and_count_limits() {
        let mut store = SqliteStore::open_in_memory().expect("open sqlite in memory");
        let first = candidate("app:test", "Test App", "/Applications/Test.app");
        store.upsert_candidates(&[first]).expect("insert candidate");

        store
            .conn
            .execute(
                "INSERT INTO usage_events(candidate_id, action, used_at_unix_s) VALUES (?1, ?2, ?3)",
                params!["app:test", "open", 100_i64],
            )
            .expect("insert old usage");
        store
            .conn
            .execute(
                "INSERT INTO usage_events(candidate_id, action, used_at_unix_s) VALUES (?1, ?2, ?3)",
                params!["app:test", "open", 200_i64],
            )
            .expect("insert usage 2");
        store
            .conn
            .execute(
                "INSERT INTO usage_events(candidate_id, action, used_at_unix_s) VALUES (?1, ?2, ?3)",
                params!["app:test", "open", 300_i64],
            )
            .expect("insert usage 3");

        let removed_old = store
            .prune_usage_events_older_than(150)
            .expect("prune old usage");
        assert_eq!(removed_old, 1);

        let removed_overflow = store
            .prune_usage_events_to_max(1)
            .expect("prune usage overflow");
        assert_eq!(removed_overflow, 1);

        let remaining: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM usage_events", [], |row| row.get(0))
            .expect("count remaining usage");
        assert_eq!(remaining, 1);
    }
}

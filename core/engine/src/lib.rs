pub mod action;
pub mod config;
pub mod config_path;
pub mod index;
pub mod modes;
mod normalize;
mod platform;
mod query;
pub mod result;
mod scoring;
mod search;

pub use action::{ActionKind, LaunchAction};
use config::RuntimeConfig;
/// Re-exported so a shell can validate a usage verb without depending on the
/// indexing crate for one enum.
pub use lumio_indexing::UsageAction;
use lumio_indexing::{Candidate, CandidateIdKind, CandidateKind};
use lumio_storage::{SqliteStore, StorageError};
use normalize::normalize_for_search;
pub use result::{LaunchResult, LaunchResultAction};
use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const INDEX_UPSERT_CHUNK_SIZE: usize = 512;
const USAGE_RETENTION_DAYS: i64 = 90;
const MAX_USAGE_EVENT_ROWS: usize = 50_000;

struct IndexedCandidate {
    candidate: Candidate,
    // Search-normalized fields are precomputed once at load time so the query loop
    // does not allocate per candidate/per keystroke.
    title_search: String,
    subtitle_search: Option<String>,
    path_search: String,
}

#[derive(Default)]
pub struct QueryEngine {
    candidates: Vec<IndexedCandidate>,
    folder_ids: HashSet<Box<str>>,
    search_aliases: HashMap<String, Vec<String>>,
}

impl QueryEngine {
    pub fn new(candidates: Vec<Candidate>) -> Self {
        let runtime_config = RuntimeConfig::default();
        Self::new_with_config(candidates, &runtime_config)
    }

    pub fn new_with_config(candidates: Vec<Candidate>, config: &RuntimeConfig) -> Self {
        let candidates: Vec<_> = candidates
            .into_iter()
            .filter(|candidate| {
                !platform::is_excluded_browser_app(candidate)
                    && (candidate.kind != CandidateKind::Folder
                        || !index::should_exclude_folder(
                            Path::new(candidate.path.as_ref()),
                            config,
                        ))
            })
            .map(IndexedCandidate::new)
            .collect();
        let folder_ids = candidates
            .iter()
            .filter(|entry| entry.candidate.kind == CandidateKind::Folder)
            .map(|entry| entry.candidate.id.clone())
            .collect();
        let search_aliases = config.search_aliases.clone();

        Self {
            candidates,
            folder_ids,
            search_aliases,
        }
    }

    pub fn search(&self, query: &str, limit: usize) -> Vec<LaunchResult> {
        let scored = self.search_scored(query, limit);
        scored
            .into_iter()
            .map(|(candidate, score)| LaunchResult::from((&candidate, score)))
            .collect()
    }

    /// Number of indexed candidates, without materializing any results.
    pub fn candidate_count(&self) -> usize {
        self.candidates.len()
    }

    /// Tests whether an ambiguous filesystem event involved an indexed directory.
    pub fn contains_indexed_folder(&self, path: &Path) -> bool {
        let Some(path) = path.to_str() else {
            return false;
        };
        let id = index::folder_candidate_id(path);
        self.folder_ids.contains(id.as_str())
    }

    pub fn record_usage_in_memory(&mut self, candidate_id: &str, used_at_unix_s: i64) -> bool {
        if let Some(indexed) = self
            .candidates
            .iter_mut()
            .find(|c| c.candidate.id.as_ref() == candidate_id)
        {
            indexed.candidate.use_count = indexed.candidate.use_count.saturating_add(1);
            indexed.candidate.last_used_at_unix_s = Some(used_at_unix_s);
            return true;
        }
        false
    }

    pub fn demo_seed() -> Self {
        Self::new(Self::demo_candidates())
    }

    pub fn demo_candidates() -> Vec<Candidate> {
        vec![
            Candidate::new(
                "app:terminal",
                CandidateKind::App,
                "Terminal",
                "/System/Applications/Utilities/Terminal.app",
            ),
            Candidate::new(
                "app:vscode",
                CandidateKind::App,
                "Visual Studio Code",
                "/Applications/Visual Studio Code.app",
            ),
        ]
    }

    pub fn from_sqlite(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        let runtime_config = RuntimeConfig::load_cached();
        let store = SqliteStore::open(path)?;
        let candidates = store.load_candidates(None)?;
        Ok(Self::new_with_config(candidates, &runtime_config))
    }

    pub fn bootstrap_sqlite(path: impl AsRef<Path>) -> Result<(), StorageError> {
        Self::bootstrap_sqlite_scoped(path, BootstrapScope::ALL)
    }

    /// Like `bootstrap_sqlite`, but only re-walks the sources selected by `scope`
    /// and only prunes stale rows whose candidate id matches one of those sources.
    /// Used by the application watcher to refresh apps without rescanning settings.
    pub fn bootstrap_sqlite_scoped(
        path: impl AsRef<Path>,
        scope: BootstrapScope,
    ) -> Result<(), StorageError> {
        let mut store = SqliteStore::open(path)?;
        let runtime_config = RuntimeConfig::load_cached();
        let run_started_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|err| StorageError::Data(format!("system time error: {err}")))?
            .as_secs() as i64;
        if store.is_demo_seeded()? {
            // Clear demo rows first, then progressively stream real candidates.
            store.delete_unseen_candidates(
                &HashSet::new(),
                i64::MAX,
                &BootstrapScope::ALL.id_prefixes(),
            )?;
        }

        let (rx, producer_handle) =
            index::discover_candidates_stream_scoped(&runtime_config, scope).into_parts();
        let mut seen = HashSet::new();
        let mut chunk = Vec::with_capacity(INDEX_UPSERT_CHUNK_SIZE);
        let mut discovered_count = 0usize;
        for candidate in rx {
            if !seen.insert(candidate.id.clone()) {
                continue;
            }
            discovered_count += 1;
            chunk.push(candidate);
            if chunk.len() >= INDEX_UPSERT_CHUNK_SIZE {
                store.upsert_candidates_indexed(&chunk, Some(run_started_at))?;
                chunk.clear();
            }
        }

        if !chunk.is_empty() {
            store.upsert_candidates_indexed(&chunk, Some(run_started_at))?;
        }

        if let Err(err) = producer_handle.join() {
            eprintln!("lumio index: producer worker panicked: {err:?}");
        }

        // Stale-row sweep. The `ALL` branch keeps the "discovered something"
        // guard as a crash-shaped failsafe - if a full bootstrap silently
        // produced zero candidates we'd rather leave the DB alone than wipe
        // every row. Scoped paths are different: when the watcher fires an
        // `APPS_ONLY` refresh, "zero discovered" is the legitimate "user just
        // uninstalled their last app in this root" outcome, and we must still
        // sweep the matching prefixes or the deleted row lingers forever
        // (only an `ALL` refresh would otherwise catch it).
        // Prune by the `seen` set rather than the old "indexed_at < run_started"
        // sweep: the change-detecting upsert no
        // longer bumps indexed_at on unchanged rows, so only "not seen this scan"
        // reliably means "gone". delete_unseen_candidates keeps the indexed_at<run
        // guard to preserve i64::MAX pinned rows. `seen` is already collected above
        // for dedup, so this reuses it.
        // TODO(indexing-scale Direction A): this still required a full walk to
        // build `seen`. Event-driven incremental indexing (watcher paths) would
        // delete only the paths the watcher reported removed.
        let prefixes = scope.id_prefixes();
        if !prefixes.is_empty() && (!scope.is_all() || discovered_count > 0) {
            let _ = store.delete_unseen_candidates(&seen, run_started_at, &prefixes)?;
        }

        let usage_cutoff = run_started_at.saturating_sub(USAGE_RETENTION_DAYS * 24 * 3600);
        let _ = store.prune_usage_events_older_than(usage_cutoff)?;
        let _ = store.prune_usage_events_to_max(MAX_USAGE_EVENT_ROWS)?;

        Ok(())
    }
}

impl IndexedCandidate {
    fn new(candidate: Candidate) -> Self {
        // Normalize once; reuse for fuzzy/contains/path scoring.
        let title_search = normalize_for_search(&candidate.title);
        let subtitle_search = candidate
            .subtitle
            .as_ref()
            .map(|subtitle| normalize_for_search(subtitle));
        #[cfg(windows)]
        let path_search = normalize_for_search(&candidate.path.replace('\\', "/"));
        #[cfg(not(windows))]
        let path_search = normalize_for_search(&candidate.path);
        Self {
            candidate,
            title_search,
            subtitle_search,
            path_search,
        }
    }
}

/// Selects which discovery sources `bootstrap_sqlite_scoped` should re-walk.
/// Each source maps 1:1 to a candidate id prefix; only candidates with those
/// prefixes are eligible for the post-walk stale sweep.
#[derive(Debug, Clone, Copy)]
pub struct BootstrapScope {
    pub apps: bool,
    pub folders: bool,
    pub settings: bool,
}

impl BootstrapScope {
    pub const ALL: Self = Self {
        apps: true,
        folders: true,
        settings: true,
    };
    pub const APPS_ONLY: Self = Self {
        apps: true,
        folders: false,
        settings: false,
    };
    pub const FOLDERS_ONLY: Self = Self {
        apps: false,
        folders: true,
        settings: false,
    };

    pub fn is_all(&self) -> bool {
        self.apps && self.folders && self.settings
    }

    pub fn is_empty(&self) -> bool {
        !(self.apps || self.folders || self.settings)
    }

    pub(crate) fn id_prefixes(&self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.apps {
            out.push(CandidateIdKind::PREFIX_APP);
        }
        if self.folders {
            out.push(CandidateIdKind::PREFIX_FOLDER);
        }
        if self.settings {
            out.push(CandidateIdKind::PREFIX_SETTING);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scoring::default_browse_score;

    #[test]
    fn bootstrap_scope_all_includes_every_source() {
        let s = BootstrapScope::ALL;
        assert!(s.is_all());
        assert!(!s.is_empty());
        assert!(s.apps && s.folders && s.settings);
    }

    #[test]
    fn bootstrap_scope_apps_only_picks_only_app_prefix() {
        let prefixes = BootstrapScope::APPS_ONLY.id_prefixes();
        assert_eq!(prefixes, vec![CandidateIdKind::PREFIX_APP]);
        assert!(!BootstrapScope::APPS_ONLY.is_all());
        assert!(!BootstrapScope::APPS_ONLY.is_empty());
    }

    #[test]
    fn bootstrap_scope_all_yields_every_prefix() {
        let prefixes = BootstrapScope::ALL.id_prefixes();
        assert_eq!(
            prefixes,
            vec![
                CandidateIdKind::PREFIX_APP,
                CandidateIdKind::PREFIX_FOLDER,
                CandidateIdKind::PREFIX_SETTING,
            ]
        );
    }

    #[test]
    fn bootstrap_scope_empty_is_detectable() {
        let s = BootstrapScope {
            apps: false,
            folders: false,
            settings: false,
        };
        assert!(s.is_empty());
        assert!(!s.is_all());
        assert!(s.id_prefixes().is_empty());
    }

    fn sample_engine() -> QueryEngine {
        QueryEngine::new(vec![
            Candidate::new(
                "app:terminal",
                CandidateKind::App,
                "Terminal",
                "/System/Applications/Utilities/Terminal.app",
            ),
            Candidate::new(
                "app:vscode",
                CandidateKind::App,
                "Visual Studio Code",
                "/Applications/Visual Studio Code.app",
            ),
        ])
    }

    #[test]
    fn app_prefix_filters_to_apps() {
        let engine = sample_engine();
        let results = engine.search_scored("a\"term", 10);
        assert!(
            results
                .iter()
                .all(|(candidate, _)| candidate.kind == CandidateKind::App)
        );
        assert!(
            results
                .iter()
                .any(|(candidate, _)| candidate.id.as_ref() == "app:terminal")
        );
    }

    #[test]
    fn vietnamese_diacritics_query_matches_ascii_titles() {
        let engine = QueryEngine::new(vec![Candidate::new(
            "app:terminal",
            CandidateKind::App,
            "Terminal",
            "/System/Applications/Utilities/Terminal.app",
        )]);

        let results = engine.search_scored("tẻrminal", 10);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.id.as_ref(), "app:terminal");
    }

    #[test]
    fn keychain_query_matches_keychain_access_app() {
        let engine = QueryEngine::new(vec![
            Candidate::new(
                "app:keychain",
                CandidateKind::App,
                "Keychain Access",
                "/System/Library/CoreServices/Applications/Keychain Access.app",
            ),
            Candidate::new(
                "app:archive",
                CandidateKind::App,
                "Archive Utility",
                "/System/Library/CoreServices/Applications/Archive Utility.app",
            ),
        ]);

        let results = engine.search_scored("keychain", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("app:keychain")
        );
    }

    #[test]
    fn empty_query_prioritizes_recent_and_frequent_apps() {
        let mut frequent_app = Candidate::new(
            "app.frequent",
            CandidateKind::App,
            "Frequent",
            "/Applications/Frequent.app",
        );
        frequent_app.use_count = 25;
        frequent_app.last_used_at_unix_s = Some(4_102_444_800);

        let mut less_used_app = Candidate::new(
            "app.less",
            CandidateKind::App,
            "Less",
            "/Applications/Less.app",
        );
        less_used_app.use_count = 1;

        let engine = QueryEngine::new(vec![less_used_app, frequent_app]);
        let results = engine.search_scored("", 4);
        let ordered_ids: Vec<&str> = results
            .iter()
            .map(|(candidate, _)| candidate.id.as_ref())
            .collect();

        assert_eq!(ordered_ids[0], "app.frequent");
        assert_eq!(ordered_ids[1], "app.less");
    }

    #[test]
    fn empty_query_can_prioritize_frequent_settings_entries() {
        let now = 1_775_462_400; // 2026-04-06 16:00:00 UTC

        let mut display_setting = Candidate::new(
            "setting:com.apple.displays-settings.extension",
            CandidateKind::App,
            "Display",
            "x-apple.systempreferences:com.apple.displays-settings.extension",
        );
        display_setting.subtitle = Some("System Settings display monitor".into());
        display_setting.use_count = 16;
        display_setting.last_used_at_unix_s = Some(now - 60 * 60 * 20);

        let mut newly_opened_app = Candidate::new(
            "app.new",
            CandidateKind::App,
            "Newly Opened",
            "/Applications/Newly Opened.app",
        );
        newly_opened_app.use_count = 1;
        newly_opened_app.last_used_at_unix_s = Some(now);

        assert!(
            default_browse_score(&display_setting, now)
                > default_browse_score(&newly_opened_app, now)
        );

        let engine = QueryEngine::new(vec![newly_opened_app, display_setting]);
        let results = engine.search_scored("", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("setting:com.apple.displays-settings.extension")
        );
    }

    #[test]
    fn empty_query_prefers_more_recent_app_when_usage_is_equal() {
        // Use actual current time so test works regardless of when it runs
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let mut display_setting = Candidate::new(
            "setting:com.apple.displays-settings.extension",
            CandidateKind::App,
            "Display",
            "x-apple.systempreferences:com.apple.displays-settings.extension",
        );
        display_setting.subtitle = Some("System Settings display monitor".into());
        display_setting.use_count = 1;
        display_setting.last_used_at_unix_s = Some(now - 60 * 60 * 12); // 12 hours ago

        let mut newly_opened_app = Candidate::new(
            "app.new",
            CandidateKind::App,
            "Newly Opened",
            "/Applications/Newly Opened.app",
        );
        newly_opened_app.use_count = 1;
        newly_opened_app.last_used_at_unix_s = Some(now); // Just now

        assert!(
            default_browse_score(&newly_opened_app, now)
                > default_browse_score(&display_setting, now)
        );

        let engine = QueryEngine::new(vec![display_setting, newly_opened_app]);
        let results = engine.search_scored("", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("app.new")
        );
    }

    #[test]
    fn app_scoped_path_query_matches_nested_app_paths() {
        let engine = QueryEngine::new(vec![
            Candidate::new(
                "app.editor",
                CandidateKind::App,
                "Editor",
                "/Users/test/Applications/editors/portable/Editor.app",
            ),
            Candidate::new(
                "app.other",
                CandidateKind::App,
                "Other",
                "/Applications/Other.app",
            ),
        ]);

        let results = engine.search_scored("a\"editors/portable", 10);
        assert!(!results.is_empty());
        assert_eq!(results[0].0.id.as_ref(), "app.editor");
    }

    #[test]
    fn ambiguous_query_ingo_prefers_relevant_app_over_settings_alias_noise() {
        let mut settings = Candidate::new(
            "setting:network",
            CandidateKind::App,
            "Network",
            "x-apple.systempreferences:com.apple.preference.network",
        );
        settings.subtitle =
            Some("System Settings settings network ethernet dns proxy vpn notifications".into());

        let app = Candidate::new(
            "app.concurrency",
            CandidateKind::App,
            "Concurrency in Go",
            "/Applications/Concurrency in Go.app",
        );

        let engine = QueryEngine::new(vec![settings, app]);
        let results = engine.search_scored("ingo", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("app.concurrency")
        );
    }

    #[test]
    fn settings_scope_matches_pane_subtitles_without_returning_folders() {
        let mut settings_app = Candidate::new(
            "setting:general",
            CandidateKind::App,
            "General",
            "x-apple.systempreferences:com.apple.preference.general",
        );
        settings_app.subtitle = Some("System Settings settings general".into());

        let settings_folder = Candidate::new(
            "folder:settings",
            CandidateKind::Folder,
            "settings",
            "/Users/test/Documents/settings",
        );

        let engine = QueryEngine::new(vec![settings_folder, settings_app]);
        let results = engine.search_scored("s\"sett", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("setting:general")
        );
    }

    #[test]
    fn alias_note_promotes_matching_app_results() {
        let mut config = RuntimeConfig::default();
        config
            .search_aliases
            .insert("note".to_string(), vec!["notion".to_string()]);

        let app = Candidate::new(
            "app.notion",
            CandidateKind::App,
            "Notion",
            "/Applications/Notion.app",
        );
        let folder = Candidate::new(
            "folder:notes",
            CandidateKind::Folder,
            "Notes",
            "/Users/test/Documents/Notes",
        );

        let engine = QueryEngine::new_with_config(vec![app, folder], &config);
        let results = engine.search_scored("note", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("app.notion")
        );
    }

    #[test]
    fn alias_brow_does_not_promote_archive_for_arc_term() {
        let mut config = RuntimeConfig::default();
        config
            .search_aliases
            .insert("brow".to_string(), vec!["arc".to_string()]);

        let mut archive = Candidate::new(
            "app.archive",
            CandidateKind::App,
            "Archive Utility",
            "/System/Library/CoreServices/Applications/Archive Utility.app",
        );
        archive.use_count = 2_000;

        let arc = Candidate::new(
            "app.arc",
            CandidateKind::App,
            "Arc",
            "/Applications/Arc.app",
        );

        let engine = QueryEngine::new_with_config(vec![archive, arc], &config);
        let results = engine.search_scored("brow", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("app.arc")
        );
    }

    #[test]
    fn alias_can_match_system_settings_subtitle_terms() {
        let mut config = RuntimeConfig::default();
        config
            .search_aliases
            .insert("update".to_string(), vec!["software update".to_string()]);

        let mut settings = Candidate::new(
            "setting:update",
            CandidateKind::App,
            "General",
            "x-apple.systempreferences:com.apple.preference.general",
        );
        settings.subtitle = Some("System Settings software update".into());

        let app = Candidate::new(
            "app.updates",
            CandidateKind::App,
            "General Helper",
            "/Applications/General Helper.app",
        );

        let engine = QueryEngine::new_with_config(vec![app, settings], &config);
        let results = engine.search_scored("update", 10);
        assert_eq!(
            results.first().map(|(candidate, _)| candidate.id.as_ref()),
            Some("setting:update")
        );
    }
}

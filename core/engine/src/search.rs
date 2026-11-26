use crate::QueryEngine;
use crate::query::{ParsedQuery, SearchScope};
use crate::scoring::{
    ScoredMatch, contains_match_score, default_browse_score, finalize_top_k,
    is_macos_settings_application, is_settings_landing_query, kind_bias, looks_like_settings_query,
    path_depth_penalty, path_match_score, push_top_k, query_kind_penalty_with_settings_flag,
};
use lumio_indexing::{Candidate, CandidateKind};
use lumio_matching::{
    PreparedQuery, fuzzy_quality_bonus_prepared, fuzzy_score_prepared, prepare_query,
};
use lumio_ranking::rank_score;
use std::collections::BinaryHeap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const RERANK_POOL_MULTIPLIER: usize = 4;
const RERANK_TOP_N: usize = 80;
const RERANK_MIN_QUERY_CHARS: usize = 3;
const SCORE_ALIAS_TITLE_MATCH: i64 = 1_520;
const SCORE_ALIAS_SUBTITLE_MATCH: i64 = 1_260;

impl QueryEngine {
    fn has_term_boundary_match(haystack: &str, term: &str) -> bool {
        if term.is_empty() {
            return false;
        }

        for (start, _) in haystack.match_indices(term) {
            let end = start + term.len();
            let left_ok = haystack[..start]
                .chars()
                .next_back()
                .is_none_or(|ch| !ch.is_alphanumeric());
            let right_ok = haystack[end..]
                .chars()
                .next()
                .is_none_or(|ch| !ch.is_alphanumeric());
            if left_ok && right_ok {
                return true;
            }
        }

        false
    }
    fn alias_match_score(
        alias_terms: &[String],
        title_search: &str,
        subtitle_search: Option<&str>,
    ) -> Option<i64> {
        let mut best = None;
        for term in alias_terms {
            if Self::has_term_boundary_match(title_search, term) {
                best = Some(best.unwrap_or(0).max(SCORE_ALIAS_TITLE_MATCH));
            }

            if subtitle_search.is_some_and(|subtitle| Self::has_term_boundary_match(subtitle, term))
            {
                best = Some(best.unwrap_or(0).max(SCORE_ALIAS_SUBTITLE_MATCH));
            }
        }
        best
    }

    fn search_empty_query(&self, scope: SearchScope, limit: usize) -> Vec<ScoredMatch<'_>> {
        // Empty-query mode is a browse ranking pass: usage + recency, no text matching.
        let now_unix_s = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let mut top = BinaryHeap::new();
        for (idx, candidate) in self.candidates.iter().enumerate() {
            if !scope.matches(&candidate.candidate) {
                continue;
            }
            let score = default_browse_score(&candidate.candidate, now_unix_s);
            push_top_k(
                &mut top,
                ScoredMatch::new(idx as u32, score, &candidate.candidate.title),
                limit,
            );
        }

        finalize_top_k(top)
    }

    fn search_folder_path(&self, query: &str, limit: usize) -> Vec<ScoredMatch<'_>> {
        // The launcher resolves explicit absolute or home-relative addresses itself.
        // An unresolved absolute path must not turn into a fuzzy match elsewhere.
        if query.starts_with('/') || query.starts_with("~/") {
            return Vec::new();
        }

        let terms: Vec<_> = query
            .split('/')
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .map(|part| (part, prepare_query(part)))
            .collect();
        if terms.is_empty() {
            return Vec::new();
        }

        let browse_children = query.ends_with('/');
        let match_limit = if browse_children { 1 } else { limit };
        let mut top = BinaryHeap::new();
        for (idx, indexed) in self.candidates.iter().enumerate() {
            if indexed.candidate.kind != CandidateKind::Folder {
                continue;
            }
            if let Some(score) = folder_path_score(&terms, &indexed.path_search) {
                push_top_k(
                    &mut top,
                    ScoredMatch::new(idx as u32, score, &indexed.candidate.title),
                    match_limit,
                );
            }
        }

        let matches = finalize_top_k(top);
        if !browse_children {
            return matches;
        }

        let Some(parent) = matches.first() else {
            return matches;
        };
        let parent = Path::new(self.candidates[parent.idx as usize].candidate.path.as_ref());
        self.search_folder_children(parent, limit)
    }

    /// A trailing slash opens the matched folder for browsing. Compare actual
    /// parent paths so similar or repeated path names don't mix their children.
    fn search_folder_children(&self, parent: &Path, limit: usize) -> Vec<ScoredMatch<'_>> {
        let mut top = BinaryHeap::new();
        for (idx, indexed) in self.candidates.iter().enumerate() {
            let candidate = &indexed.candidate;
            if candidate.kind == CandidateKind::Folder
                && Path::new(candidate.path.as_ref()).parent() == Some(parent)
            {
                push_top_k(
                    &mut top,
                    ScoredMatch::new(idx as u32, 0, &candidate.title),
                    limit,
                );
            }
        }
        finalize_top_k(top)
    }

    fn search_text_query(
        &self,
        normalized_query: &str,
        scope: SearchScope,
        limit: usize,
    ) -> Vec<ScoredMatch<'_>> {
        // Stage 1: fast retrieval over all candidates into a bounded top-K pool.
        let prepared_query = prepare_query(normalized_query);
        let mut top = BinaryHeap::new();
        let has_path_hint = normalized_query.contains('/');
        // Query-level flag reused across all candidates in this search pass.
        let settings_query =
            scope == SearchScope::Settings || looks_like_settings_query(normalized_query);
        let prefer_apps = scope == SearchScope::All && !settings_query;
        let settings_landing =
            scope != SearchScope::Settings && is_settings_landing_query(normalized_query);
        let pool_limit = (limit.saturating_mul(RERANK_POOL_MULTIPLIER)).max(RERANK_TOP_N);
        let alias_terms = self.search_aliases.get(normalized_query);

        for (idx, candidate) in self.candidates.iter().enumerate() {
            let is_settings_pane = SearchScope::Settings.matches(&candidate.candidate);
            if !scope.matches(&candidate.candidate) || (settings_landing && is_settings_pane) {
                continue;
            }
            let is_settings_application =
                settings_landing && is_macos_settings_application(&candidate.candidate);
            // Use precomputed normalized strings from IndexedCandidate.
            // This avoids normalize_for_search allocations in the hot loop.
            let title_score = fuzzy_score_prepared(&prepared_query, &candidate.title_search);
            let subtitle_search = if !settings_query && is_settings_pane {
                None
            } else {
                candidate.subtitle_search.as_deref()
            };
            let subtitle_score = subtitle_search
                .as_ref()
                .and_then(|subtitle| fuzzy_score_prepared(&prepared_query, subtitle))
                .map(|value| value / 2);
            let contains_score =
                contains_match_score(normalized_query, &candidate.title_search, subtitle_search);
            let path_score = if has_path_hint {
                path_match_score(normalized_query, &candidate.path_search)
            } else {
                None
            };
            let alias_score = alias_terms.and_then(|terms| {
                if candidate.candidate.kind == CandidateKind::App {
                    // Alias boosts are app-only to avoid distorting folder ranking.
                    return Self::alias_match_score(
                        terms,
                        &candidate.title_search,
                        candidate.subtitle_search.as_deref(),
                    );
                }
                None
            });

            let base = [
                title_score,
                subtitle_score,
                contains_score,
                path_score,
                alias_score,
                is_settings_application.then_some(SCORE_ALIAS_TITLE_MATCH),
            ]
            .into_iter()
            .flatten()
            .max();

            let Some(base) = base else {
                continue;
            };

            let final_score = rank_score(
                base,
                normalized_query,
                &candidate.candidate,
                &candidate.title_search,
            ) + kind_bias(&candidate.candidate)
                // Reuse precomputed query kind to keep this hot loop allocation-free.
                + query_kind_penalty_with_settings_flag(settings_query, &candidate.candidate)
                + path_depth_penalty(&candidate.candidate);
            // Apply priority before the heap limit so strong matches from
            // other groups cannot crowd matching apps out of the result set.
            let preferred = is_settings_application
                || (prefer_apps
                    && candidate.candidate.kind == CandidateKind::App
                    && !is_settings_pane);
            push_top_k(
                &mut top,
                ScoredMatch::new(idx as u32, final_score, &candidate.candidate.title)
                    .with_priority(preferred),
                pool_limit,
            );
        }

        let mut ranked = finalize_top_k(top);

        if normalized_query.chars().count() < RERANK_MIN_QUERY_CHARS {
            return ranked;
        }

        // Stage 2: quality rerank only the leading window to keep latency bounded.
        // Two-stage retrieval:
        // 1) fast scorer over full candidate set
        // 2) quality rerank only on top-N candidates to keep latency predictable
        let rerank_count = ranked.len().min(RERANK_TOP_N);
        for entry in ranked.iter_mut().take(rerank_count) {
            // Reuse the precomputed normalized title from IndexedCandidate rather
            // than re-normalizing here on every rerank.
            let title_search = &self.candidates[entry.idx as usize].title_search;
            entry.score += fuzzy_quality_bonus_prepared(&prepared_query, title_search);
        }

        ranked.sort();
        ranked
    }

    pub fn search_scored(&self, query: &str, limit: usize) -> Vec<(Candidate, i64)> {
        if limit == 0 {
            return vec![];
        }

        let parsed_query = ParsedQuery::from_input(query);
        let indices = if parsed_query.normalized_query.is_empty() {
            self.search_empty_query(parsed_query.scope, limit)
        } else if parsed_query.is_folder_path() {
            self.search_folder_path(&parsed_query.normalized_query, limit)
        } else {
            self.search_text_query(&parsed_query.normalized_query, parsed_query.scope, limit)
        };

        // Materialize Candidates only for the final top-K - the hot scoring loop
        // kept everything as (index, score) pairs to avoid per-push clones.
        indices
            .into_iter()
            .take(limit)
            .map(|entry| {
                (
                    self.candidates[entry.idx as usize].candidate.clone(),
                    entry.score,
                )
            })
            .collect()
    }
}

/// Resolves an abbreviated suffix such as d/t against adjacent path components
/// ending at the candidate itself.
fn folder_path_score(terms: &[(&str, PreparedQuery<'_>)], path: &str) -> Option<i64> {
    let mut components = path.rsplit('/').filter(|part| !part.is_empty());
    let mut total = 0;
    for (needle, prepared) in terms.iter().rev() {
        let component = components.next()?;
        total += if component == *needle {
            2_000
        } else if component.starts_with(*needle) {
            1_500 - ((component.len() - needle.len()) as i64).min(250)
        } else {
            fuzzy_score_prepared(prepared, component)?.clamp(0, 999)
        };
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::QueryEngine;
    use lumio_indexing::{Candidate, CandidateKind};

    #[test]
    fn app_priority_survives_the_candidate_limit_and_keeps_app_relevance() {
        let mut candidates = vec![
            Candidate::new(
                "app:prefix",
                CandidateKind::App,
                "Monitor Pro",
                "/Applications/Monitor Pro.app",
            ),
            Candidate::new(
                "app:contains",
                CandidateKind::App,
                "Desk Monitor",
                "/Applications/Desk Monitor.app",
            ),
            Candidate::new(
                "setting:monitor",
                CandidateKind::App,
                "Monitor",
                "x-apple.systempreferences:monitor",
            ),
        ];
        // Exact folders outrank fuzzy apps by score alone, even before reranking.
        candidates.extend((0..100).map(|index| {
            Candidate::new(
                &format!("folder:{index}"),
                CandidateKind::Folder,
                "Monitor",
                &format!("/Users/me/Documents/{index}/Monitor"),
            )
        }));
        let engine = QueryEngine::new(candidates);
        assert_eq!(engine.search("monitor", 1)[0].id, "app:prefix");
        let rows = engine.search("monitor", 4);
        assert_eq!(rows[0].id, "app:prefix");
        assert_eq!(rows[1].id, "app:contains");
        assert_eq!(rows[2].id, "setting:monitor");
        assert_eq!(rows[3].kind, "folder");
        assert_eq!(engine.search("d\"monitor", 1)[0].kind, "folder");
        assert_eq!(engine.search("s\"monitor", 1)[0].id, "setting:monitor");
    }

    #[test]
    fn bare_settings_queries_find_the_system_application_without_its_panes() {
        let mut pane = Candidate::new(
            "setting:privacy",
            CandidateKind::App,
            "Privacy",
            "x-apple.systempreferences:privacy",
        );
        pane.subtitle = Some("System Settings settings privacy permissions".into());
        let mut settings_app = Candidate::new(
            "app:system-settings",
            CandidateKind::App,
            "系统设置",
            "/System/Applications/System Settings.app",
        );
        settings_app.subtitle = Some("System Settings".into());
        let engine = QueryEngine::new(vec![
            pane,
            settings_app,
            Candidate::new(
                "app:settings-manager",
                CandidateKind::App,
                "Settings Manager",
                "/Applications/Settings Manager.app",
            ),
        ]);

        for query in [
            "settings",
            "system settings",
            "preferences",
            "系统设置",
            "系統設定",
        ] {
            let rows = engine.search(query, 10);
            assert_eq!(rows[0].id, "app:system-settings", "{query}");
            assert!(
                !rows.iter().any(|row| row.id == "setting:privacy"),
                "{query}"
            );
        }
        assert_eq!(engine.search("sys", 10)[0].id, "app:system-settings");
        assert_eq!(engine.search("s\"", 10)[0].id, "setting:privacy");
        assert_eq!(
            engine.search("privacy settings", 10)[0].id,
            "setting:privacy"
        );
    }

    #[test]
    fn abbreviations_match_adjacent_folder_components_only() {
        let folder = |id, name, path| Candidate::new(id, CandidateKind::Folder, name, path);
        let engine = QueryEngine::new(vec![
            folder("folder:telegram", "Telegram", "/home/me/Downloads/Telegram"),
            folder(
                "folder:deep",
                "Telegram",
                "/home/me/Downloads/archive/Telegram",
            ),
            folder("folder:child", "child", "/home/me/Downloads/Telegram/child"),
            Candidate::new(
                "app:telegram",
                CandidateKind::App,
                "Telegram",
                "/Applications/Downloads/Telegram.app",
            ),
        ]);

        for input in ["D/T", "d\"D/T", "Dwlds/Tlgrm", "Dównlóads/Télegram"] {
            let results = engine.search(input, 20);
            assert_eq!(results.len(), 1, "{input}: {results:?}");
            assert_eq!(results[0].id, "folder:telegram", "{input}");
        }
        let nested = engine.search("D/T/C", 20);
        assert_eq!(nested.len(), 1);
        assert_eq!(nested[0].id, "folder:child");
        assert!(engine.search("Telegram/Downloads", 20).is_empty());
    }

    #[test]
    fn path_components_rank_exact_then_prefix_then_fuzzy() {
        let folder = |id, name, path| Candidate::new(id, CandidateKind::Folder, name, path);
        let engine = QueryEngine::new(vec![
            folder("folder:fuzzy", "other", "/home/me/Drafts/other"),
            folder("folder:prefix", "telegram", "/home/me/Downloads/telegram"),
            folder("folder:exact", "t", "/home/me/d/t"),
        ]);

        let ids: Vec<_> = engine
            .search("D/T", 20)
            .into_iter()
            .map(|row| row.id)
            .collect();
        assert_eq!(ids, ["folder:exact", "folder:prefix", "folder:fuzzy"]);
    }

    #[test]
    fn trailing_slash_browses_only_the_matched_folders_immediate_children() {
        let folder = |id, name, path| Candidate::new(id, CandidateKind::Folder, name, path);
        let engine = QueryEngine::new(vec![
            folder("downloads", "Downloads", "/home/me/Downloads"),
            folder("telegrams", "Telegrams", "/home/me/Downloads/Telegrams"),
            folder("images", "Images", "/home/me/Downloads/Telegrams/Images"),
            folder(
                "archive",
                ".archive",
                "/home/me/Downloads/Telegrams/.archive",
            ),
            folder("nested", "2026", "/home/me/Downloads/Telegrams/Images/2026"),
            folder(
                "similar",
                "Telegrams Old",
                "/home/me/Downloads/Telegrams/Downloads/Telegrams Old",
            ),
            folder(
                "unrelated",
                "Unrelated",
                "/home/me/Downloads/Telegrams/Downloads/Telegrams Old/Unrelated",
            ),
            Candidate::new(
                "app:tool",
                CandidateKind::App,
                "Tool",
                "/home/me/Downloads/Telegrams/Tool.app",
            ),
        ]);
        let ids = |query| {
            engine
                .search(query, 20)
                .into_iter()
                .map(|row| row.id)
                .collect::<Vec<_>>()
        };

        let matched_folders = ids("D/T");
        assert_eq!(matched_folders[0], "telegrams");
        assert!(!matched_folders.iter().any(|id| id == "images"));
        for query in ["D/T/", "d\"D/T/", "Downloads/Telegrams/"] {
            assert_eq!(ids(query), ["archive", "images"], "{query}");
        }
        assert_eq!(ids("Downloads/"), ["telegrams"]);
        assert_eq!(ids("D/T/I/"), ["nested"]);
        assert!(ids("D/T/I/2026/").is_empty());
        assert!(ids("D/No Such Directory/").is_empty());
        assert!(ids("/home/me/Downloads/").is_empty());
        assert!(ids("~/Downloads/").is_empty());
    }

    #[test]
    fn abbreviations_work_for_other_path_names_and_end_at_the_requested_level() {
        let folder = |id, name, path| Candidate::new(id, CandidateKind::Folder, name, path);
        let engine = QueryEngine::new(vec![
            folder("telegrams", "Telegrams", "/Users/me/Downloads/Telegrams"),
            folder("images", "Images", "/Users/me/Downloads/Telegrams/Images"),
            folder(
                "support",
                "Application Support",
                "/Users/me/Library/Application Support",
            ),
            folder("nvim", "nvim", "/Users/me/.config/nvim"),
            folder("drafts", "drafts", "/Users/me/Projects/Lumio/drafts"),
            folder(
                "archived",
                "drafts",
                "/Users/me/Projects/Lumio/Archive/drafts",
            ),
        ]);

        for (query, expected) in [
            ("D/T", "telegrams"),
            ("D/T/I", "images"),
            (".c/n", "nvim"),
            ("Pr/Lu/dr", "drafts"),
        ] {
            let results = engine.search(query, 20);
            assert_eq!(
                results
                    .iter()
                    .map(|row| row.id.as_str())
                    .collect::<Vec<_>>(),
                [expected],
                "{query}"
            );
        }
        assert_eq!(engine.search("L/AS", 20)[0].id, "support");
    }

    #[test]
    fn term_boundary_match_rejects_inner_substring() {
        assert!(!QueryEngine::has_term_boundary_match(
            "archive utility",
            "arc"
        ));
    }

    #[test]
    fn term_boundary_match_accepts_full_token() {
        assert!(QueryEngine::has_term_boundary_match("arc browser", "arc"));
        assert!(QueryEngine::has_term_boundary_match("arc-browser", "arc"));
    }
}

use crate::config::*;
use lumio_indexing::CandidateIdKind;
use lumio_indexing::{Candidate, CandidateKind};
use std::cmp::Ordering;
use std::collections::BinaryHeap;

const SETTINGS_SUBTITLE_PREFIX: &str = "System Settings";
const BROWSE_USAGE_LOG_SCALE: f64 = 60.0;

const RECENT_LAST_HOUR_BOOST: i64 = 140;
const RECENT_TODAY_BOOST: i64 = 90;
const RECENT_THIS_WEEK_BOOST: i64 = 40;
const RECENT_THIS_MONTH_BOOST: i64 = 12;

const SETTINGS_ON_NON_SETTINGS_QUERY_PENALTY: i64 = -180;

pub(crate) fn contains_match_score(
    query: &str,
    title: &str,
    subtitle: Option<&str>,
) -> Option<i64> {
    if title.contains(query) {
        return Some(SCORE_TITLE_CONTAINS);
    }

    if let Some(sub) = subtitle
        && sub.contains(query)
    {
        return Some(SCORE_SUBTITLE_CONTAINS);
    }

    let mut has_terms = false;
    let all_match = query.split_whitespace().all(|t| {
        has_terms = true;
        title.contains(t) || subtitle.is_some_and(|sub| sub.contains(t))
    });

    if has_terms && all_match {
        return Some(SCORE_TOKEN_ALL_MATCH);
    }

    None
}

pub(crate) fn path_match_score(query: &str, path: &str) -> Option<i64> {
    if !query.contains('/') {
        return None;
    }

    let normalized = query.trim().trim_matches('/');
    if normalized.is_empty() {
        return None;
    }

    if path.contains(normalized) {
        // A path that ends with the query is the folder the user named; paths
        // that merely contain it mid-string are its descendants, so rank the
        // exact target above them (otherwise ties break alphabetically and a
        // child like `.../domain/commands` can outrank `.../domain`).
        if path.ends_with(normalized) {
            return Some(1_500);
        }
        return Some(1_350);
    }

    let tokens: Vec<&str> = normalized
        .split('/')
        .filter(|token| !token.is_empty())
        .collect();
    if tokens.len() < 2 {
        return None;
    }

    let mut cursor = 0usize;
    let mut total_gap = 0usize;
    for &token in &tokens {
        let remaining = &path[cursor..];
        let found_at = remaining.find(token)?;
        total_gap += found_at;
        cursor += found_at + token.len();
    }

    let penalty = (total_gap as i64).min(250);
    let mut score = 1_050 - penalty;
    // Fuzzy edition of the ends_with rule above: descendants walk the same
    // tokens with the same gaps as the folder the user named (trailing path
    // is free), so they would tie and alphabetical order could put a child
    // like `.../domain/commands` first. When the query's last segment names
    // the path's final component, boost the named entry above them. The cap
    // (1_050 + 150) keeps every fuzzy match below the literal 1_350/1_500.
    if let (Some(&last_token), Some(last_slash)) = (tokens.last(), path.rfind('/'))
        && path[last_slash + 1..].contains(last_token)
    {
        score += 150;
    }
    Some(score)
}

pub(crate) fn kind_bias(candidate: &Candidate) -> i64 {
    match candidate.kind {
        CandidateKind::App => BIAS_APP,
        CandidateKind::Folder => BIAS_FOLDER,
        CandidateKind::Action => BIAS_ACTION,
    }
}

pub(crate) fn query_kind_penalty_with_settings_flag(
    settings_query: bool,
    candidate: &Candidate,
) -> i64 {
    // Callers can precompute `settings_query` once per search query to avoid
    // repeating hint detection for every candidate in the scoring loop.
    if settings_query {
        match candidate.kind {
            CandidateKind::App => {
                if is_system_settings_candidate(candidate) {
                    BIAS_SETTINGS_MATCH
                } else {
                    BIAS_APP_ON_SETTINGS_QUERY
                }
            }
            CandidateKind::Folder | CandidateKind::Action => BIAS_NON_APP_ON_SETTINGS_QUERY,
        }
    } else if is_system_settings_candidate(candidate) {
        SETTINGS_ON_NON_SETTINGS_QUERY_PENALTY
    } else {
        0
    }
}

pub(crate) fn looks_like_settings_query(query: &str) -> bool {
    query.contains("设置")
        || query.contains("設定")
        || query
            .split_whitespace()
            .any(|word| matches!(word, "setting" | "settings" | "preference" | "preferences"))
}

pub(crate) fn is_settings_landing_query(query: &str) -> bool {
    matches!(
        query,
        "setting"
            | "settings"
            | "system settings"
            | "preference"
            | "preferences"
            | "system preferences"
            | "设置"
            | "系统设置"
            | "系统偏好设置"
            | "設定"
            | "系統設定"
            | "系統偏好設定"
    )
}

pub(crate) fn is_system_settings_candidate(candidate: &Candidate) -> bool {
    candidate.id.starts_with(CandidateIdKind::PREFIX_SETTING)
        || candidate
            .subtitle
            .as_deref()
            .unwrap_or("")
            .contains(SETTINGS_SUBTITLE_PREFIX)
}

pub(crate) fn is_macos_settings_application(candidate: &Candidate) -> bool {
    candidate.kind == CandidateKind::App
        && candidate.path.as_ref() == "/System/Applications/System Settings.app"
}

pub(crate) fn path_depth_penalty(candidate: &Candidate) -> i64 {
    if candidate.kind != CandidateKind::Folder {
        return 0;
    }
    let depth = candidate
        .path
        .split('/')
        .filter(|part| !part.is_empty())
        .count() as i64;
    -(depth / 2)
}

pub(crate) fn default_browse_score(candidate: &Candidate, now_unix_s: i64) -> i64 {
    let kind_boost = match candidate.kind {
        CandidateKind::App => 600,
        CandidateKind::Folder => 120,
        CandidateKind::Action => BROWSE_BOOST_ACTION,
    };

    let frequency = ((candidate.use_count as f64 + 1.0).log2() * BROWSE_USAGE_LOG_SCALE) as i64;
    let recency = candidate
        .last_used_at_unix_s
        .map(|last| {
            let age_s = (now_unix_s - last).max(0);
            let age_hours = age_s / 3600;
            browse_recency_boost(age_hours)
        })
        .unwrap_or(0);

    kind_boost + frequency + recency
}

fn browse_recency_boost(age_hours: i64) -> i64 {
    match age_hours {
        0 => RECENT_LAST_HOUR_BOOST,
        1..=24 => RECENT_TODAY_BOOST - ((age_hours - 1) / 4),
        25..=168 => RECENT_THIS_WEEK_BOOST - ((age_hours - 25) / 12),
        169..=720 => RECENT_THIS_MONTH_BOOST - ((age_hours - 169) / 72),
        _ => 0,
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct ScoredMatch<'a> {
    pub(crate) idx: u32,
    pub(crate) score: i64,
    preferred: bool,
    // Borrowed title powers the BinaryHeap tiebreak without cloning the Candidate.
    // Lifetime is scoped to the candidate slice, which outlives the heap.
    title: &'a str,
}

impl PartialEq for ScoredMatch<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.preferred == other.preferred && self.score == other.score && self.title == other.title
    }
}

impl Eq for ScoredMatch<'_> {}

impl<'a> ScoredMatch<'a> {
    pub(crate) fn new(idx: u32, score: i64, title: &'a str) -> Self {
        Self {
            idx,
            score,
            preferred: false,
            title,
        }
    }

    pub(crate) fn with_priority(mut self, preferred: bool) -> Self {
        self.preferred = preferred;
        self
    }
}

impl Ord for ScoredMatch<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .preferred
            .cmp(&self.preferred)
            .then_with(|| other.score.cmp(&self.score))
            .then_with(|| self.title.cmp(other.title))
    }
}

impl PartialOrd for ScoredMatch<'_> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub(crate) fn push_top_k<'a>(
    heap: &mut BinaryHeap<ScoredMatch<'a>>,
    item: ScoredMatch<'a>,
    limit: usize,
) {
    if heap.len() < limit {
        heap.push(item);
        return;
    }

    if let Some(worst) = heap.peek()
        && item < *worst
    {
        let _ = heap.pop();
        heap.push(item);
    }
}

pub(crate) fn finalize_top_k(heap: BinaryHeap<ScoredMatch<'_>>) -> Vec<ScoredMatch<'_>> {
    // The heap keeps the worst eligible match at its root; ascending order is best-first.
    heap.into_sorted_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app(title: &str, path: &str) -> Candidate {
        Candidate::new(
            &format!("app.{}", title.to_lowercase()),
            CandidateKind::App,
            title,
            path,
        )
    }

    #[test]
    fn contains_match_title_scores_higher_than_subtitle() {
        let title_score = contains_match_score("safari", "safari browser", None).unwrap();
        let subtitle_score =
            contains_match_score("safari", "other", Some("safari browser")).unwrap();
        assert!(title_score > subtitle_score);
    }

    #[test]
    fn contains_match_returns_none_when_no_match() {
        assert!(contains_match_score("xyz", "safari", Some("browser")).is_none());
    }

    #[test]
    fn contains_match_multi_token_all_present() {
        let score = contains_match_score("visual code", "visual studio code", None);
        assert!(score.is_some());
    }

    #[test]
    fn contains_match_multi_token_partial_returns_none() {
        assert!(contains_match_score("visual xyz", "visual studio code", None).is_none());
    }

    #[test]
    fn path_match_requires_slash() {
        assert!(path_match_score("safari", "/Applications/Safari.app").is_none());
    }

    #[test]
    fn path_match_exact_substring() {
        let score = path_match_score("git/books-pc", "/Users/test/git/books-pc/README.md");
        assert!(score.is_some());
        assert!(score.unwrap() > 1_000);
    }

    #[test]
    fn path_match_multi_segment_fuzzy() {
        let score = path_match_score("Users/Documents", "/Users/test/Documents/notes.txt");
        assert!(score.is_some());
    }

    #[test]
    fn path_match_exact_target_outranks_descendants() {
        let query = "kunkka-coffee/domain";
        let exact = path_match_score(query, "/users/x/git/kunkka-coffee/domain");
        let child = path_match_score(query, "/users/x/git/kunkka-coffee/domain/commands");
        assert!(
            exact > child,
            "the named folder ({exact:?}) should beat its child ({child:?})"
        );
    }

    #[test]
    fn path_match_fuzzy_target_outranks_descendants() {
        // "kunkka-co" is a partial segment, so the literal contains/ends_with
        // branch never fires and the token walk decides the order.
        let query = "kunkka-co/domain";
        let exact = path_match_score(query, "/users/x/git/kunkka-coffee/domain");
        let child = path_match_score(query, "/users/x/git/kunkka-coffee/domain/commands");
        assert!(exact.is_some());
        assert!(
            exact > child,
            "the named folder ({exact:?}) should beat its child ({child:?})"
        );
    }

    #[test]
    fn path_match_fuzzy_partial_last_segment_outranks_descendants() {
        let query = "kunkka-co/dom";
        let exact = path_match_score(query, "/users/x/git/kunkka-coffee/domain");
        let child = path_match_score(query, "/users/x/git/kunkka-coffee/domain/commands");
        assert!(
            exact > child,
            "a partial last segment ({exact:?}) should still beat the child ({child:?})"
        );
    }

    #[test]
    fn path_match_fuzzy_bonus_stays_below_literal_match() {
        let fuzzy = path_match_score("kunkka-co/domain", "/users/x/git/kunkka-coffee/domain");
        let literal = path_match_score("coffee/domain", "/users/x/git/kunkka-coffee/domain/file");
        assert!(
            fuzzy < literal,
            "fuzzy + bonus ({fuzzy:?}) must not outrank a literal substring match ({literal:?})"
        );
    }

    #[test]
    fn path_match_single_segment_returns_none() {
        assert!(path_match_score("test/", "/some/path").is_none());
    }

    #[test]
    fn default_browse_score_prefers_frequent_apps() {
        let mut frequent = app("Safari", "/Applications/Safari.app");
        frequent.use_count = 50;
        frequent.last_used_at_unix_s = Some(1_700_000_000);

        let unused = app("Chess", "/Applications/Chess.app");

        let now = 1_700_000_100;
        assert!(default_browse_score(&frequent, now) > default_browse_score(&unused, now));
    }

    #[test]
    fn push_top_k_respects_limit() {
        let titles: Vec<String> = (0..10).map(|i| format!("App{i}")).collect();
        let mut heap = BinaryHeap::new();
        for (i, title) in titles.iter().enumerate() {
            push_top_k(
                &mut heap,
                ScoredMatch::new(i as u32, (i as i64) * 100, title.as_str()),
                3,
            );
        }
        assert_eq!(heap.len(), 3);

        let results = finalize_top_k(heap);
        assert!(results[0].score >= results[1].score);
        assert!(results[1].score >= results[2].score);
    }

    #[test]
    fn query_kind_penalty_settings_hints() {
        let settings_app = Candidate {
            id: "app:settings".into(),
            kind: CandidateKind::App,
            title: "System Settings".into(),
            subtitle: Some("System Settings".into()),
            path: "/System/Applications/System Settings.app".into(),
            ..Default::default()
        };
        let regular_app = app("Safari", "/Applications/Safari.app");
        let action = Candidate::new("src:task:network", CandidateKind::Action, "network", "");

        let settings_score = query_kind_penalty_with_settings_flag(true, &settings_app);
        let app_score = query_kind_penalty_with_settings_flag(true, &regular_app);
        let action_score = query_kind_penalty_with_settings_flag(true, &action);

        assert!(settings_score > app_score);
        assert!(app_score > action_score);
    }

    #[test]
    fn query_kind_penalty_demotes_settings_for_non_settings_queries() {
        let settings_app = Candidate {
            id: "setting:network".into(),
            kind: CandidateKind::App,
            title: "Network".into(),
            subtitle: Some("System Settings network".into()),
            path: "x-apple.systempreferences:com.apple.preference.network".into(),
            ..Default::default()
        };

        assert!(query_kind_penalty_with_settings_flag(false, &settings_app) < 0);
    }

    #[test]
    fn query_kind_penalty_precomputed_flag_matches_detected_query_kind() {
        let settings_app = Candidate {
            id: "setting:network".into(),
            kind: CandidateKind::App,
            title: "Network".into(),
            subtitle: Some("System Settings network".into()),
            path: "x-apple.systempreferences:com.apple.preference.network".into(),
            ..Default::default()
        };
        let regular_app = app("Safari", "/Applications/Safari.app");
        let regular_action = Candidate::new("src:task:notes", CandidateKind::Action, "notes", "");

        let settings_like = "network settings";
        let non_settings_like = "network";

        assert_eq!(
            query_kind_penalty_with_settings_flag(
                looks_like_settings_query(settings_like),
                &settings_app
            ),
            query_kind_penalty_with_settings_flag(true, &settings_app)
        );
        assert_eq!(
            query_kind_penalty_with_settings_flag(
                looks_like_settings_query(settings_like),
                &regular_app
            ),
            query_kind_penalty_with_settings_flag(true, &regular_app)
        );
        assert_eq!(
            query_kind_penalty_with_settings_flag(
                looks_like_settings_query(non_settings_like),
                &settings_app,
            ),
            query_kind_penalty_with_settings_flag(false, &settings_app)
        );
        assert_eq!(
            query_kind_penalty_with_settings_flag(
                looks_like_settings_query(non_settings_like),
                &regular_action,
            ),
            query_kind_penalty_with_settings_flag(false, &regular_action)
        );
    }

    #[test]
    fn looks_like_settings_query_requires_an_explicit_settings_word() {
        assert!(looks_like_settings_query("display settings"));
        assert!(looks_like_settings_query("设置"));
        assert!(!looks_like_settings_query("sett"));
        assert!(!looks_like_settings_query("displaylink"));
        assert!(!looks_like_settings_query("network"));
        assert!(!looks_like_settings_query("ingo"));
    }

    #[test]
    fn default_browse_score_recency_tiers_prefer_more_recent_candidates() {
        let now = 1_775_462_400;
        let mut candidate = app("Recent", "/Applications/Recent.app");
        candidate.use_count = 1;

        let mut last_hour = candidate.clone();
        last_hour.last_used_at_unix_s = Some(now - 10 * 60);

        let mut today = candidate.clone();
        today.last_used_at_unix_s = Some(now - 6 * 3600);

        let mut week = candidate.clone();
        week.last_used_at_unix_s = Some(now - 3 * 24 * 3600);

        let mut old = candidate;
        old.last_used_at_unix_s = Some(now - 60 * 24 * 3600);

        assert!(default_browse_score(&last_hour, now) > default_browse_score(&today, now));
        assert!(default_browse_score(&today, now) > default_browse_score(&week, now));
        assert!(default_browse_score(&week, now) > default_browse_score(&old, now));
    }
}

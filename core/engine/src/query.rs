use crate::normalize::normalize_for_search;
use lumio_indexing::CandidateKind;

// Query prefixes: leading letter matched case-insensitively, trailing `"`
// exactly (see `strip_query_prefix`).
const PREFIX_APPS: &[u8] = b"a\"";
const PREFIX_FOLDERS: &[u8] = b"d\"";

#[derive(Clone, Debug)]
pub(crate) struct ParsedQuery {
    pub(crate) normalized_query: String,
    pub(crate) kind_filter: Option<CandidateKind>,
}

impl ParsedQuery {
    pub(crate) fn from_input(input: &str) -> Self {
        #[cfg(windows)]
        let input = input.replace('\\', "/");
        let trimmed = input.trim();
        if let Some(rest) = strip_query_prefix(trimmed, PREFIX_FOLDERS) {
            return Self {
                normalized_query: normalize_for_search(rest),
                kind_filter: Some(CandidateKind::Folder),
            };
        }

        if let Some(rest) = strip_query_prefix(trimmed, PREFIX_APPS) {
            return Self {
                normalized_query: normalize_for_search(rest),
                kind_filter: Some(CandidateKind::App),
            };
        }

        Self {
            normalized_query: normalize_for_search(trimmed),
            kind_filter: trimmed.contains('/').then_some(CandidateKind::Folder),
        }
    }

    pub(crate) fn is_folder_path(&self) -> bool {
        self.kind_filter == Some(CandidateKind::Folder) && self.normalized_query.contains('/')
    }
}

/// Strips a `…"` query prefix, returning the trimmed text after it (or `None`
/// when `input` doesn't start with `prefix`). The prefix is matched ASCII
/// case-insensitively - the trailing `"` has no case, so it matches exactly.
/// `prefix` is all-ASCII, so its length is always a UTF-8 char boundary in a
/// matched input.
fn strip_query_prefix<'a>(input: &'a str, prefix: &[u8]) -> Option<&'a str> {
    let bytes = input.as_bytes();
    if bytes.len() < prefix.len() || !bytes[..prefix.len()].eq_ignore_ascii_case(prefix) {
        return None;
    }
    Some(input[prefix.len()..].trim())
}

#[cfg(test)]
mod tests {
    use super::ParsedQuery;
    use lumio_indexing::CandidateKind;

    #[test]
    fn app_prefix_sets_filter() {
        let parsed = ParsedQuery::from_input("A\"safari");
        assert_eq!(parsed.kind_filter, Some(CandidateKind::App));
        assert_eq!(parsed.normalized_query, "safari");
    }

    #[test]
    fn path_queries_search_only_folders() {
        for input in ["D/T", "d\"D/T"] {
            let parsed = ParsedQuery::from_input(input);
            assert_eq!(parsed.kind_filter, Some(CandidateKind::Folder));
            assert_eq!(parsed.normalized_query, "d/t");
            assert!(parsed.is_folder_path());
        }
    }

    #[test]
    fn removed_prefixes_are_plain_text() {
        for input in ["f\"document", "rc\"report", "r\"foo"] {
            assert!(ParsedQuery::from_input(input).kind_filter.is_none());
        }
    }
}

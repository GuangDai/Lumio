//! Launch modes: the names a command line or a URL uses to open Lumio already in
//! a particular mode (`lumio files`).
//!
//! One rule for every row: the query is `prefix` followed by the term. Adding a
//! mode is adding a row; a shell that needs a `match` over mode names has
//! bypassed this table.

#[derive(Clone, Copy, Debug)]
pub struct Mode {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    /// Text placed in the input. A term is appended to it verbatim.
    pub prefix: &'static str,
    /// One line, for `--list-modes`.
    pub about: &'static str,
}

impl Mode {
    pub fn query(&self, term: &str) -> String {
        format!("{}{}", self.prefix, term)
    }
}

/// Listed in this order. The `:` rows keep their trailing space: it is the
/// jump's trigger, not padding.
pub const MODES: &[Mode] = &[
    Mode {
        name: "apps",
        aliases: &["app"],
        prefix: "a\"",
        about: "applications only",
    },
    Mode {
        name: "files",
        aliases: &["file"],
        prefix: "f\"",
        about: "files only",
    },
    Mode {
        name: "folders",
        aliases: &["folder", "dirs"],
        prefix: "d\"",
        about: "folders only",
    },
    Mode {
        name: "processes",
        aliases: &["ps"],
        prefix: "ps\"",
        about: "find and kill running processes",
    },
    Mode {
        name: "speed",
        aliases: &[],
        prefix: ":speed ",
        about: "network speed test",
    },
    Mode {
        name: "kill",
        aliases: &[],
        prefix: ":kill ",
        about: "running processes",
    },
];

/// The single resolution point: an unmatched name is where a future fallback
/// goes (user-declared blocks are the obvious candidate), which only stays
/// possible while callers ask here instead of matching names themselves.
pub fn resolve(name: &str) -> Option<&'static Mode> {
    let wanted = name.trim();
    if wanted.is_empty() {
        return None;
    }
    MODES.iter().find(|mode| {
        mode.name.eq_ignore_ascii_case(wanted)
            || mode
                .aliases
                .iter()
                .any(|alias| alias.eq_ignore_ascii_case(wanted))
    })
}

/// A term from the `lumio://` scheme is literal search text and nothing else: no
/// command panel (`:`), no quote to re-target the prefix.
/// The URL is reachable from content the user did not write; argv is not, and
/// is not filtered by this.
///
/// Trimmed first, or one leading space walks `:kill` straight through.
pub fn url_term_is_safe(term: &str) -> bool {
    let trimmed = term.trim_start();
    !(trimmed.starts_with(':') || term.contains('"'))
}

/// Rendered in core so both shells print the same listing.
pub fn list_text() -> String {
    let width = MODES.iter().map(|mode| mode.name.len()).max().unwrap_or(0);
    let mut out = String::new();
    for mode in MODES {
        let aliases = if mode.aliases.is_empty() {
            String::new()
        } else {
            format!(" ({})", mode.aliases.join(", "))
        };
        out.push_str(&format!("{:<width$}  {}{aliases}\n", mode.name, mode.about));
    }
    out
}

/// For tooling, so a picker or shell completion never hardcodes the list.
pub fn list_json() -> String {
    let rows: Vec<serde_json::Value> = MODES
        .iter()
        .map(|mode| {
            serde_json::json!({
                "name": mode.name,
                "aliases": mode.aliases,
                "prefix": mode.prefix,
                "about": mode.about,
                "platforms": "all",
            })
        })
        .collect();
    serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".to_string())
}

/// A launch request parsed from the command line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Launch {
    /// Open as today. Unrecognised arguments land here, which is what keeps
    /// existing autostart lines working.
    Normal,
    Query {
        text: String,
    },
    ListModes,
    /// Named a mode and got it wrong. An error because they were specific,
    /// unlike a bare word that just means "open".
    UnknownMode(String),
}

/// Arguments after the program name. Precedence: a bare mode name, then
/// `--list-modes`, `--mode`, `--query`.
pub fn parse_args<I, S>(args: I) -> Launch
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let args: Vec<String> = args
        .into_iter()
        .map(|arg| arg.as_ref().to_string())
        .collect();

    // Before any flag parsing, so the rest is the term verbatim:
    // `lumio kill chrome` has to keep its term.
    if let Some(first) = args.first()
        && let Some(mode) = resolve(first)
    {
        return Launch::Query {
            text: mode.query(&args[1..].join(" ")),
        };
    }

    // `--` ends the options, for a term that starts with a hyphen.
    let (flags, mut verbatim) = match args.iter().position(|arg| arg == "--") {
        Some(at) => (&args[..at], args[at + 1..].to_vec()),
        None => (&args[..], Vec::new()),
    };

    let mut positionals: Vec<String> = Vec::new();
    let mut mode_name: Option<String> = None;
    let mut query: Option<String> = None;
    let mut list_modes = false;
    let mut saw_mode_flag = false;

    let mut index = 0;
    while index < flags.len() {
        match flags[index].as_str() {
            "--list-modes" => list_modes = true,
            "--mode" => {
                saw_mode_flag = true;
                if let Some(value) = flags.get(index + 1)
                    && !value.starts_with('-')
                {
                    mode_name = Some(value.clone());
                    index += 1;
                }
            }
            "--query" => {
                if let Some(value) = flags.get(index + 1) {
                    query = Some(value.clone());
                    index += 1;
                }
            }
            other if !other.starts_with('-') => positionals.push(other.to_string()),
            _ => {}
        }
        index += 1;
    }
    positionals.append(&mut verbatim);

    // `--mode` with no name lists rather than erroring: a keybinding has no
    // terminal, so the useful failure is the one that teaches.
    if list_modes || (saw_mode_flag && mode_name.is_none()) {
        return Launch::ListModes;
    }

    if let Some(name) = mode_name {
        return match resolve(&name) {
            Some(mode) => Launch::Query {
                text: mode.query(&positionals.join(" ")),
            },
            None => Launch::UnknownMode(name),
        };
    }

    if let Some(text) = query {
        return Launch::Query { text };
    }

    Launch::Normal
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mode_resolves_by_name_and_by_alias() {
        assert_eq!(resolve("files").unwrap().name, "files");
        assert_eq!(resolve("file").unwrap().name, "files");
    }

    #[test]
    fn resolution_ignores_case_and_surrounding_space() {
        assert_eq!(resolve("Files").unwrap().name, "files");
        assert_eq!(resolve("  FILE  ").unwrap().name, "files");
    }

    #[test]
    fn an_unknown_name_resolves_to_nothing_rather_than_guessing() {
        assert!(resolve("unknown").is_none());
        assert!(resolve("").is_none());
        assert!(resolve("   ").is_none());
    }

    #[test]
    fn a_term_is_appended_to_the_prefix() {
        assert_eq!(resolve("file").unwrap().query("report"), "f\"report");
        assert_eq!(resolve("kill").unwrap().query("chrome"), ":kill chrome");
        assert_eq!(resolve("file").unwrap().query(""), "f\"");
    }

    /// A row whose prefix is not real grammar ships as a mode that opens an
    /// empty search, which reads as the feature being broken.
    #[test]
    fn every_prefix_is_grammar_the_app_actually_parses() {
        for mode in MODES {
            let query_prefix = mode.prefix.ends_with('"');
            // The trailing space is the `:` jump's trigger, not decoration.
            let command_jump = mode.prefix.starts_with(':') && mode.prefix.ends_with(' ');

            assert!(
                query_prefix || command_jump,
                "mode {} has prefix {:?}, which is none of: a query prefix ending in a quote, \
                 a `:command ` jump with its trailing space",
                mode.name,
                mode.prefix
            );
        }
    }

    #[test]
    fn no_two_rows_answer_to_the_same_word() {
        let mut seen = std::collections::HashSet::new();
        for mode in MODES {
            assert!(seen.insert(mode.name), "duplicate mode name: {}", mode.name);
            for alias in mode.aliases {
                assert!(
                    seen.insert(alias),
                    "alias {alias} collides with another mode or alias"
                );
            }
        }
    }

    #[test]
    fn a_url_term_may_not_reach_a_command_panel() {
        assert!(!url_term_is_safe(":kill 123"));
        // The quote would re-target the search onto a different prefix.
        assert!(!url_term_is_safe("x\"y"));
    }

    #[test]
    fn leading_space_does_not_smuggle_a_command_past_the_check() {
        assert!(!url_term_is_safe("   :kill 123"));
    }

    #[test]
    fn ordinary_search_text_is_allowed_through() {
        assert!(url_term_is_safe("password"));
        assert!(url_term_is_safe("quarterly report 2026"));
        assert!(url_term_is_safe("a:b"));
        assert!(url_term_is_safe(""));
    }

    fn parse(args: &[&str]) -> Launch {
        parse_args(args.iter().copied())
    }

    fn shown(text: &str) -> Launch {
        Launch::Query {
            text: text.to_string(),
        }
    }

    #[test]
    fn a_bare_mode_name_opens_that_mode() {
        assert_eq!(parse(&["files"]), shown("f\""));
        assert_eq!(parse(&["file"]), shown("f\""));
    }

    #[test]
    fn a_term_rides_along_with_the_mode() {
        assert_eq!(parse(&["files", "report"]), shown("f\"report"));
        assert_eq!(
            parse(&["--mode", "files", "quarterly", "report"]),
            shown("f\"quarterly report")
        );
    }

    /// Every WM autostart line in the README depends on this.
    #[test]
    fn an_unrecognised_bare_word_still_just_opens_lumio() {
        assert_eq!(parse(&["unknown"]), Launch::Normal);
        assert_eq!(parse(&[]), Launch::Normal);
        assert_eq!(parse(&["--some-future-flag"]), Launch::Normal);
    }

    #[test]
    fn an_explicit_unknown_mode_is_an_error() {
        assert_eq!(
            parse(&["--mode", "unknown"]),
            Launch::UnknownMode("unknown".to_string())
        );
    }

    #[test]
    fn asking_for_a_mode_without_naming_one_lists_them() {
        assert_eq!(parse(&["--mode"]), Launch::ListModes);
        assert_eq!(parse(&["--list-modes"]), Launch::ListModes);
        // A flag after `--mode` is not a mode name.
        assert_eq!(parse(&["--mode", "--list-modes"]), Launch::ListModes);
    }

    #[test]
    fn query_passes_grammar_through_untouched() {
        assert_eq!(parse(&["--query", "f\"invoice"]), shown("f\"invoice"));
        assert_eq!(parse(&["--query", ":kill chrome"]), shown(":kill chrome"));
    }

    /// `lumio kill chrome` used to lose trailing args, which is exactly the
    /// kind of term the free-text modes exist for.
    #[test]
    fn a_term_keeps_its_hyphenated_arguments() {
        assert_eq!(parse(&["kill", "chrome"]), shown(":kill chrome"));
        assert_eq!(
            parse(&["--mode", "kill", "--", "chrome"]),
            shown(":kill chrome")
        );
    }

    #[test]
    fn an_explicit_mode_wins_over_a_positional() {
        assert_eq!(parse(&["--mode", "kill", "chrome"]), shown(":kill chrome"));
    }

    /// An alias that goes unlisted is a way in nobody can find.
    #[test]
    fn the_listing_names_every_mode_and_alias() {
        let listing = list_text();
        for mode in MODES {
            assert!(listing.contains(mode.name), "missing mode {}", mode.name);
            for alias in mode.aliases {
                assert!(listing.contains(alias), "missing alias {alias}");
            }
        }
    }

    /// Locked because neither shell's crate compiles everywhere. The plugin
    /// hands over a `Vec<String>` including argv[0], hence the skip.
    #[test]
    fn the_iterator_shapes_the_shells_use_all_compile() {
        let forwarded: Vec<String> = vec!["lumio".into(), "files".into(), "pass".into()];
        assert_eq!(
            parse_args(forwarded.iter().skip(1)),
            shown("f\"pass"),
            "a Vec<String> argv with the program name skipped"
        );

        let owned: Vec<String> = vec!["file".into()];
        assert_eq!(parse_args(owned.into_iter()), shown("f\""));

        assert_eq!(parse_args(["file"].iter().copied()), shown("f\""));
        assert_eq!(
            parse_args(std::env::args().skip(usize::MAX)),
            Launch::Normal
        );
    }

    #[test]
    fn the_json_listing_is_valid_and_complete() {
        let parsed: serde_json::Value =
            serde_json::from_str(&list_json()).expect("should be valid JSON");

        assert_eq!(
            parsed.as_array().expect("should be an array").len(),
            MODES.len()
        );
    }
}

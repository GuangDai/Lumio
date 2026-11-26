use crate::config::RuntimeConfig;
use crate::platform::paths::{candidate_id_path_component, path_is_same_or_child};
use lumio_indexing::{Candidate, CandidateIdKind, CandidateKind};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc;

pub(crate) fn folder_candidate_id(path: &str) -> String {
    let prefix = CandidateIdKind::PREFIX_FOLDER;
    format!("{prefix}{}", candidate_id_path_component(path))
}

pub(super) fn discover_folders(config: &RuntimeConfig, tx: mpsc::SyncSender<Candidate>) {
    let mut pending = VecDeque::new();
    let mut seen = HashSet::new();

    let mut roots: Vec<_> = config
        .folder_scan_roots
        .iter()
        .chain(&config.folder_scan_extra_roots)
        .map(PathBuf::from)
        .collect();
    // Older configs put the Home root after its children. Prioritize shallow
    // roots so they can queue their direct children before deeper roots fill the budget.
    roots.sort_by_key(|path| path.components().count());
    for path in roots {
        if path.is_dir() {
            queue_folder(
                &mut pending,
                &mut seen,
                path,
                config.folder_scan_depth,
                config,
            );
        }
    }

    // Discover shallow folders before traversing large subtrees such as Library.
    while let Some((path, depth, candidate)) = pending.pop_front() {
        if tx.send(candidate).is_err() {
            return;
        }
        if depth == 0 || seen.len() >= config.folder_scan_limit {
            continue;
        }
        let Ok(entries) = fs::read_dir(path) else {
            continue;
        };
        for entry in entries.flatten() {
            if seen.len() >= config.folder_scan_limit {
                break;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = entry.path();
            if kind.is_dir() {
                queue_folder(&mut pending, &mut seen, path, depth - 1, config);
            } else if kind.is_symlink() && path.is_dir() {
                // Show directory links without descending through them.
                queue_folder(&mut pending, &mut seen, path, 0, config);
            }
        }
    }
}

fn queue_folder(
    pending: &mut VecDeque<(PathBuf, usize, Candidate)>,
    seen: &mut HashSet<String>,
    path: PathBuf,
    depth: usize,
    config: &RuntimeConfig,
) {
    let Some(path_str) = path.to_str() else {
        return;
    };
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path_str);
    if should_exclude_folder(&path, config) {
        return;
    }

    let id = folder_candidate_id(path_str);
    if seen.len() < config.folder_scan_limit && seen.insert(id.clone()) {
        let mut candidate = Candidate::new(&id, CandidateKind::Folder, name, path_str);
        candidate.subtitle = Some(CandidateKind::Folder.as_str().into());
        pending.push_back((path, depth, candidate));
    }
}

/// Folder scan rules, also applied to cached candidates and watcher paths.
pub fn should_exclude_folder(path: &Path, config: &RuntimeConfig) -> bool {
    let Some(path_str) = path.to_str() else {
        return true;
    };
    let excluded = config.folder_exclude_paths.iter().any(|parent| {
        let parent = parent.trim();
        !parent.is_empty() && path_is_same_or_child(path_str, parent)
    });
    if excluded {
        return true;
    }
    // A scan root can live inside a directory such as /tmp. Apply name skips
    // within that root while always shielding the contents of application bundles.
    let root = config
        .folder_scan_roots
        .iter()
        .chain(&config.folder_scan_extra_roots)
        .filter(|root| path_is_same_or_child(path_str, root))
        .max_by_key(|root| root.len());
    path.ancestors().any(|ancestor| {
        let Some(name) = ancestor.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        let name = name.to_lowercase();
        let in_scan = root.map_or(ancestor == path, |root| {
            ancestor
                .to_str()
                .is_some_and(|part| path_is_same_or_child(part, root))
        });
        name.ends_with(".app") || (in_scan && config.skip_dir_names.contains(&name))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn new_root() -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("lumio-folder-test-{}-{unique}", std::process::id()))
    }

    fn indexed_folders(config: &RuntimeConfig) -> Vec<Candidate> {
        let (tx, rx) = mpsc::sync_channel(config.folder_scan_limit);
        discover_folders(config, tx);
        rx.into_iter().collect()
    }

    #[test]
    fn indexes_hidden_folders_and_library_but_skips_files_and_exclusions() {
        let root = new_root();
        for directory in [
            "Downloads/Telegram",
            "Library/Application Support",
            ".config",
            ".git/objects",
            ".ssh",
            "private/inside",
            "Tool.app/Contents",
            "node_modules/pkg",
        ] {
            fs::create_dir_all(root.join(directory)).unwrap();
        }
        fs::write(root.join("Downloads/Telegram/notes.txt"), "notes").unwrap();
        fs::write(root.join(".ssh/known_hosts"), "example").unwrap();

        let config = RuntimeConfig {
            folder_scan_roots: vec![root.to_string_lossy().into_owned()],
            folder_exclude_paths: vec![root.join("private").to_string_lossy().into_owned()],
            folder_scan_depth: 3,
            folder_scan_limit: 32,
            ..RuntimeConfig::default()
        };
        let candidates = indexed_folders(&config);
        let mut names: Vec<_> = candidates
            .iter()
            .map(|candidate| candidate.title.as_ref())
            .collect();
        names.sort_unstable();
        let mut expected = vec![
            root.file_name().unwrap().to_str().unwrap(),
            "Downloads",
            "Telegram",
            "Library",
            "Application Support",
            ".config",
            ".git",
            "objects",
            ".ssh",
        ];
        expected.sort_unstable();
        assert_eq!(names, expected);
        assert!(
            candidates
                .iter()
                .all(|candidate| candidate.kind == CandidateKind::Folder)
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn scan_budget_favors_direct_children_over_deeper_descendants() {
        let root = new_root();
        fs::create_dir_all(root.join("one/deep/nested")).unwrap();
        fs::create_dir_all(root.join("two/deep/nested")).unwrap();
        let config = RuntimeConfig {
            folder_scan_roots: vec![
                root.join("one").to_string_lossy().into_owned(),
                root.to_string_lossy().into_owned(),
            ],
            folder_scan_depth: 4,
            folder_scan_limit: 3,
            ..RuntimeConfig::default()
        };
        let candidates = indexed_folders(&config);
        assert_eq!(candidates.len(), 3);
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.title.as_ref() == "one")
        );
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.title.as_ref() == "two")
        );
        fs::remove_dir_all(root).unwrap();
    }
}

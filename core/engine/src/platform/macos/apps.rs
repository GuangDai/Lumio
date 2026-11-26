use crate::config::RuntimeConfig;
use crate::index::APP_CANDIDATE_ID_PREFIX;
use crate::platform::macos;
use crate::platform::paths::{candidate_id_path_component, path_is_same_or_child};
use lumio_indexing::{Candidate, CandidateKind};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::mpsc;

/// Used when a bundle path has no readable file stem, which should not happen
/// for a real `.app` but keeps the candidate from having an empty title.
const FALLBACK_APP_NAME: &str = "App";
const ADDITIONAL_SYSTEM_APPLICATIONS: &[&str] = &[
    "/System/Library/CoreServices/Finder.app",
    "/System/Library/CoreServices/Time Machine.app",
    "/System/Library/CoreServices/VoiceOver.app/Contents/Resources/VoiceOver Utility.app",
];

pub(crate) fn discover_installed_apps(config: &RuntimeConfig, tx: mpsc::SyncSender<Candidate>) {
    let mut bundles = Vec::new();
    for root in merged_app_scan_roots(
        &config.app_scan_roots,
        &macos::additional_app_scan_roots(),
        macos::REQUIRED_APP_SCAN_ROOTS,
    ) {
        collect_app_bundles(
            &root,
            config.app_scan_depth,
            &config.app_exclude_paths,
            &mut bundles,
        );
    }
    // Some user-facing system apps live alongside CoreServices helpers or
    // inside an app bundle. Select them individually to avoid scanning helpers.
    for &path in ADDITIONAL_SYSTEM_APPLICATIONS {
        if Path::new(path).is_dir() && !should_exclude_path(path, &config.app_exclude_paths) {
            bundles.push(path.to_owned());
        }
    }

    // Utilities are a required root even with a custom shallow scan. Avoid
    // reading the same bundle twice when its enclosing root also found it.
    let mut seen = HashSet::new();
    bundles.retain(|path| seen.insert(candidate_id_path_component(path)));
    emit_app_batch(
        &tx,
        &bundles,
        config.localized_app_names,
        &config.app_exclude_names,
    );
}

fn emit_app_batch(
    tx: &mpsc::SyncSender<Candidate>,
    bundles: &[String],
    localized_app_names: bool,
    app_exclude_names: &[String],
) {
    // Batch the Info.plist reads for identity, display titles and search names.
    let metadata = macos::read_app_bundle_metadata(bundles, localized_app_names);
    for (path, metadata) in bundles.iter().zip(metadata) {
        let Some(metadata) = metadata else {
            emit_app(tx, path, None, &[], app_exclude_names);
            continue;
        };
        if metadata.is_safari {
            continue;
        }
        let title = metadata.chinese_title.as_deref().or_else(|| {
            if localized_app_names {
                metadata.localized_name.as_deref()
            } else {
                None
            }
        });
        let search_names: Vec<_> = metadata
            .localized_name
            .iter()
            .chain(metadata.search_names.iter())
            .map(String::as_str)
            .collect();
        emit_app(tx, path, title, &search_names, app_exclude_names);
    }
}

/// Recheck cached rows as well as fresh discovery. Cached candidates have no
/// stored bundle identifier and may point to renamed Safari app bundles.
pub(crate) fn is_excluded_browser_app(candidate: &Candidate) -> bool {
    if candidate.kind != CandidateKind::App {
        return false;
    }
    let path = Path::new(candidate.path.as_ref());
    if is_safari_app_name(candidate.title.as_ref())
        || path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .is_some_and(is_safari_app_name)
    {
        return true;
    }
    if !path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("app"))
    {
        return false;
    }
    objc2::rc::autoreleasepool(|_| {
        macos::load_bundle(candidate.path.as_ref())
            .is_some_and(|bundle| macos::is_safari_bundle(&bundle))
    })
}

fn emit_app(
    tx: &mpsc::SyncSender<Candidate>,
    path: &str,
    localized: Option<&str>,
    search_names: &[&str],
    app_exclude_names: &[String],
) {
    let bundle_name = Path::new(path)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or(FALLBACK_APP_NAME);
    let title = localized.unwrap_or(bundle_name);
    if should_exclude_app(title, bundle_name, app_exclude_names)
        || search_names
            .iter()
            .any(|name| should_exclude_app_name(name, app_exclude_names))
    {
        return;
    }

    let key = format!(
        "{APP_CANDIDATE_ID_PREFIX}{}",
        candidate_id_path_component(path)
    );
    let mut candidate = Candidate::new(&key, CandidateKind::App, title, path);
    let mut names = Vec::new();
    for name in std::iter::once(bundle_name).chain(search_names.iter().copied()) {
        if name != title && !names.contains(&name) {
            names.push(name);
        }
    }
    // The launcher already searches and persists this field. Keep path tokens
    // out of plain name queries: most built-in apps live under /System.
    candidate.subtitle = (!names.is_empty()).then(|| names.join(" · ").into_boxed_str());
    let _ = tx.send(candidate);
}

fn merged_app_scan_roots(
    config_roots: &[String],
    additional_roots: &[String],
    required_roots: &[&str],
) -> Vec<String> {
    let mut out =
        Vec::with_capacity(config_roots.len() + additional_roots.len() + required_roots.len());
    let mut seen =
        HashSet::with_capacity(config_roots.len() + additional_roots.len() + required_roots.len());
    for root in config_roots.iter().chain(additional_roots.iter()) {
        let normalized = candidate_id_path_component(root);
        if seen.insert(normalized) {
            out.push(root.clone());
        }
    }

    for root in required_roots {
        let normalized = candidate_id_path_component(root);
        if seen.insert(normalized) {
            out.push((*root).to_string());
        }
    }

    out
}

/// Appends every `.app` bundle under `path` to `out`. Naming is left to the
/// caller so the Info.plist reads can be batched across the whole scan instead
/// of happening one directory entry at a time.
fn collect_app_bundles(
    path: &str,
    depth: usize,
    app_exclude_paths: &[String],
    out: &mut Vec<String>,
) {
    if should_exclude_path(path, app_exclude_paths) {
        return;
    }

    if depth == 0 {
        return;
    }

    let Ok(entries) = fs::read_dir(path) else {
        return;
    };

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };

        let app_path = entry.path();
        let is_dir = file_type.is_dir();
        let is_symlink_dir =
            file_type.is_symlink() && fs::metadata(&app_path).map(|m| m.is_dir()).unwrap_or(false);
        if !is_dir && !is_symlink_dir {
            continue;
        }

        let Some(app_path_str) = app_path.to_str() else {
            continue;
        };
        if should_exclude_path(app_path_str, app_exclude_paths) {
            continue;
        }

        if app_path_str.ends_with(macos::APP_BUNDLE_EXTENSION) {
            out.push(app_path_str.to_string());
        } else if is_dir {
            collect_app_bundles(app_path_str, depth - 1, app_exclude_paths, out);
        }
    }
}

fn should_exclude_path(path: &str, app_exclude_paths: &[String]) -> bool {
    app_exclude_paths.iter().any(|entry| {
        let normalized_exclude = entry.trim();
        if normalized_exclude.is_empty() {
            return false;
        }
        path_is_same_or_child(path, normalized_exclude)
    })
}

fn normalize_app_name(name: &str) -> String {
    let name = name.trim();
    name.strip_suffix(macos::APP_BUNDLE_EXTENSION)
        .unwrap_or(name)
        .trim()
        .to_lowercase()
}

fn should_exclude_app_name(name: &str, app_exclude_names: &[String]) -> bool {
    let normalized_name = normalize_app_name(name);
    app_exclude_names.iter().any(|entry| {
        let normalized_exclude = normalize_app_name(entry);
        !normalized_exclude.is_empty() && normalized_exclude == normalized_name
    })
}

/// Excludes on either name: `app_exclude_names` is written by hand, so it
/// holds whichever of the two the user happened to see in the launcher.
fn should_exclude_app(title: &str, bundle_name: &str, app_exclude_names: &[String]) -> bool {
    is_safari_app_name(title)
        || is_safari_app_name(bundle_name)
        || should_exclude_app_name(title, app_exclude_names)
        || should_exclude_app_name(bundle_name, app_exclude_names)
}

fn is_safari_app_name(name: &str) -> bool {
    matches!(
        normalize_app_name(name).as_str(),
        "safari" | "safari technology preview" | "safari for webkit development"
    )
}

#[cfg(test)]
mod tests {
    use super::{
        collect_app_bundles, discover_installed_apps, emit_app, emit_app_batch,
        is_excluded_browser_app, merged_app_scan_roots, should_exclude_app,
        should_exclude_app_name, should_exclude_path,
    };
    use crate::platform::macos::test_support::TempDir;
    use crate::{QueryEngine, config::RuntimeConfig};
    use lumio_indexing::{Candidate, CandidateKind};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;

    fn create_app(root: &Path, name: &str) -> PathBuf {
        let app = root.join(name);
        fs::create_dir_all(app.join("Contents")).expect("create app contents");
        app
    }

    #[cfg(unix)]
    fn symlink_dir(target: &Path, link: &Path) {
        std::os::unix::fs::symlink(target, link).expect("create symlink");
    }

    /// Mirrors `discover_installed_apps` without a `RuntimeConfig`: walk, then
    /// emit with no localized names.
    fn collect_apps_excluding(root: &Path, app_exclude_names: &[String]) -> Vec<Candidate> {
        let mut bundles = Vec::new();
        collect_app_bundles(
            root.to_str().expect("utf-8 temp path"),
            3,
            &[],
            &mut bundles,
        );

        let (tx, rx) = mpsc::sync_channel(16);
        emit_app_batch(&tx, &bundles, false, app_exclude_names);
        drop(tx);
        rx.into_iter().collect()
    }

    fn collect_apps(root: &Path) -> Vec<Candidate> {
        collect_apps_excluding(root, &[])
    }

    #[test]
    fn excludes_app_paths_by_prefix() {
        let excludes = vec!["/Applications/Utilities".to_string()];
        assert!(should_exclude_path("/Applications/Utilities", &excludes));
        assert!(should_exclude_path(
            "/Applications/Utilities/Terminal.app",
            &excludes
        ));
    }

    #[test]
    fn excludes_app_names_case_insensitively() {
        let names = vec!["safari".to_string(), "Visual Studio Code".to_string()];
        assert!(should_exclude_app_name("Safari", &names));
        assert!(should_exclude_app_name("Visual Studio Code.app", &names));
        assert!(!should_exclude_app_name("Calculator", &names));
    }

    #[test]
    fn ignores_blank_exclude_entries() {
        let excludes = vec!["  ".to_string(), "".to_string()];
        assert!(!should_exclude_path("/Applications/Utilities", &excludes));

        let names = vec![" ".to_string(), "".to_string()];
        assert!(!should_exclude_app_name("Safari", &names));
    }

    #[test]
    fn path_prefix_is_boundary_aware() {
        let excludes = vec!["/Applications/Util".to_string()];
        assert!(!should_exclude_path("/Applications/Utilities", &excludes));
    }

    #[test]
    fn merged_roots_preserve_order_and_deduplicate() {
        let roots = vec!["/Applications".to_string()];
        let additional = vec![
            "/Users/demo/Applications".to_string(),
            "/Applications/".to_string(),
        ];

        let required = vec!["/System/Library/CoreServices/Applications", "/Applications"];

        let merged = merged_app_scan_roots(&roots, &additional, &required);
        assert_eq!(
            merged,
            vec![
                "/Applications".to_string(),
                "/Users/demo/Applications".to_string(),
                "/System/Library/CoreServices/Applications".to_string()
            ]
        );
    }

    #[test]
    #[cfg(unix)]
    fn indexes_symlinked_app_bundle() {
        let tmp = TempDir::new("symlink-app");
        let real_root = tmp.path().join("Real Apps");
        let scan_root = tmp.path().join("Applications");
        fs::create_dir_all(&real_root).expect("create real root");
        fs::create_dir_all(&scan_root).expect("create scan root");
        let real_app = create_app(&real_root, "Riot Client.app");
        let link_app = scan_root.join("Client Riot.app");
        symlink_dir(&real_app, &link_app);

        let apps = collect_apps(&scan_root);

        assert_eq!(apps.len(), 1);
        assert_eq!(apps[0].title.as_ref(), "Client Riot");
        assert_eq!(
            apps[0].path.as_ref(),
            link_app.to_str().expect("utf-8 symlink path")
        );
    }

    #[test]
    #[cfg(unix)]
    fn does_not_recurse_into_non_app_symlinked_directory() {
        let tmp = TempDir::new("symlink-dir");
        let real_root = tmp.path().join("Real Apps");
        let scan_root = tmp.path().join("Applications");
        fs::create_dir_all(&real_root).expect("create real root");
        fs::create_dir_all(&scan_root).expect("create scan root");
        create_app(&real_root, "Nested.app");
        symlink_dir(&real_root, &scan_root.join("Linked Apps"));

        let apps = collect_apps(&scan_root);

        assert!(apps.is_empty());
    }

    #[test]
    fn excludes_app_by_bundle_filename() {
        let tmp = TempDir::new("exclude-filename");
        create_app(tmp.path(), "Client Riot.app");

        let apps = collect_apps_excluding(tmp.path(), &["Client Riot".to_string()]);

        assert!(apps.is_empty());
    }

    #[test]
    fn excludes_safari_variants_by_bundle_identity_after_renaming() {
        let tmp = TempDir::new("exclude-safari");
        for (index, identifier) in [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.apple.SafariForWebKitDevelopment",
            "com.apple.Safari.WebApp.123",
        ]
        .into_iter()
        .enumerate()
        {
            let app = create_app(tmp.path(), &format!("Renamed {index}.app"));
            fs::write(
                app.join("Contents/Info.plist"),
                format!(
                    r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{identifier}</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>"#
                ),
            )
            .expect("write Safari fixture info plist");
            let old_row = Candidate::new(
                "app:cached-safari",
                CandidateKind::App,
                "Renamed Browser",
                app.to_str().expect("UTF-8 app path"),
            );
            assert!(is_excluded_browser_app(&old_row));
        }
        create_app(tmp.path(), "Safari.app");
        create_app(tmp.path(), "Terminal.app");

        let apps = collect_apps(tmp.path());
        let titles: Vec<_> = apps.iter().map(|app| app.title.as_ref()).collect();
        assert_eq!(titles, vec!["Terminal"]);
    }

    /// The walk and the name resolution are separate passes zipped back
    /// together, so the collected order is the contract between them.
    #[test]
    fn collected_bundles_are_the_app_directories_only() {
        let tmp = TempDir::new("collect-bundles");
        create_app(tmp.path(), "Alpha.app");
        create_app(tmp.path(), "Beta.app");
        fs::create_dir_all(tmp.path().join("Not An App")).expect("create plain dir");

        let mut bundles = Vec::new();
        collect_app_bundles(
            tmp.path().to_str().expect("utf-8 temp path"),
            3,
            &[],
            &mut bundles,
        );
        bundles.sort();

        assert_eq!(bundles.len(), 2);
        assert!(bundles[0].ends_with("Alpha.app"));
        assert!(bundles[1].ends_with("Beta.app"));
    }

    /// A localized title is used verbatim; the bundle file name is the fallback.
    #[test]
    fn emitted_title_prefers_the_localized_name() {
        let tmp = TempDir::new("emit-title");
        let app = create_app(tmp.path(), "WeChat.app");
        let path = app.to_str().expect("utf-8 app path");

        let (tx, rx) = mpsc::sync_channel(2);
        emit_app(&tx, path, Some("微信"), &[], &[]);
        emit_app(&tx, path, None, &[], &[]);
        drop(tx);

        let titles: Vec<String> = rx.into_iter().map(|c| c.title.to_string()).collect();
        assert_eq!(titles, vec!["微信".to_string(), "WeChat".to_string()]);
    }

    #[test]
    fn excludes_app_when_bundle_name_differs_from_localized_title() {
        let excludes = vec!["WeChat".to_string()];
        assert!(should_exclude_app("微信", "WeChat", &excludes));
        assert!(should_exclude_app("WeChat", "微信", &excludes));
    }

    #[test]
    fn installed_system_app_uses_chinese_title_and_preserves_english_search() {
        let custom_root = TempDir::new("custom-app-root");
        let config = RuntimeConfig {
            app_scan_roots: vec![custom_root.path().to_string_lossy().into_owned()],
            app_scan_depth: 1,
            localized_app_names: false,
            ..RuntimeConfig::default()
        };
        let candidates: Vec<_> = std::thread::scope(|scope| {
            let (tx, rx) = mpsc::sync_channel(16);
            scope.spawn(|| discover_installed_apps(&config, tx));
            rx.into_iter().collect()
        });
        let engine = QueryEngine::new(candidates);

        for query in ["Activity Monitor", "moni", "活动监视器", "系统监视器"] {
            let matches = engine.search(query, 8);
            assert!(
                matches
                    .iter()
                    .any(|app| app.title == "活动监视器"
                        && app.path.ends_with("/Activity Monitor.app")),
                "{query}: {matches:?}"
            );
        }
        for (english, chinese) in [
            ("Finder", "访达"),
            ("Migration Assistant", "迁移助理"),
            ("Image Capture", "图像捕捉"),
        ] {
            let matches = engine.search(english, 8);
            assert!(
                matches
                    .iter()
                    .any(|app| app.title == chinese
                        && app.path.ends_with(&format!("/{english}.app"))),
                "{english}: {matches:?}"
            );
            let matches = engine.search(chinese, 8);
            assert!(
                matches
                    .iter()
                    .any(|app| app.title == chinese
                        && app.path.ends_with(&format!("/{english}.app"))),
                "{chinese}: {matches:?}"
            );
        }
    }
}

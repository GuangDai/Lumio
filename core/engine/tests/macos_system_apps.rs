#![cfg(target_os = "macos")]

use lumio_engine::config::RuntimeConfig;
use lumio_engine::index::discover_candidates_stream_scoped;
use lumio_engine::{BootstrapScope, LaunchResultAction, QueryEngine};
use lumio_indexing::{CandidateIdKind, CandidateKind};
use objc2_foundation::{NSBundle, NSString};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

// The English query, the expected Simplified Chinese title, and an alternate
// identity for apps whose bundle name can differ across macOS releases.
const STOCK_APPS: &[(&str, &str, &str)] = &[
    ("Stickies", "便笺", "com.apple.stickies"),
    ("Dictionary", "词典", "com.apple.dictionary"),
    ("Disk Utility", "磁盘工具", "com.apple.diskutility"),
    ("Print Center", "打印中心", "com.apple.printcenter"),
    ("Mission Control", "调度中心", "com.apple.exposelauncher"),
    (
        "Activity Monitor",
        "活动监视器",
        "com.apple.activitymonitor",
    ),
    ("Script Editor", "脚本编辑器", "com.apple.scripteditor2"),
    ("Screenshot", "截屏", "com.apple.screencaptureui"),
    ("Console", "控制台", "com.apple.console"),
    ("Shortcuts", "快捷指令", "com.apple.shortcuts"),
    (
        "Bluetooth File Exchange",
        "蓝牙文件交换",
        "com.apple.bluetoothfileexchange",
    ),
    (
        "VoiceOver Utility",
        "旁白实用工具",
        "com.apple.voiceoverutility",
    ),
    ("Screen Sharing", "屏幕共享", "com.apple.screensharing"),
    (
        "Migration Assistant",
        "迁移助理",
        "com.apple.migrationassistant",
    ),
    (
        "ColorSync Utility",
        "色彩同步实用工具",
        "com.apple.colorsyncutility",
    ),
    ("Time Machine", "时间机器", "com.apple.backup.launcher"),
    (
        "Digital Color Meter",
        "数码测色计",
        "com.apple.digitalcolormeter",
    ),
    ("Tips", "提示", "com.apple.tips"),
    ("Image Capture", "图像捕捉", "com.apple.image_capture"),
    ("TextEdit", "文本编辑", "com.apple.textedit"),
    ("System Information", "系统信息", "com.apple.systemprofiler"),
    (
        "Audio MIDI Setup",
        "音频 MIDI 设置",
        "com.apple.audio.audiomidisetup",
    ),
    ("Preview", "预览", "com.apple.preview"),
    ("Terminal", "终端", "com.apple.terminal"),
    ("Font Book", "字体册", "com.apple.fontbook"),
    ("Automator", "自动操作", "com.apple.automator"),
    (
        "AirPort Utility",
        "AirPort 实用工具",
        "com.apple.airport.airportutility",
    ),
    ("Grapher", "Grapher", "com.apple.grapher"),
    (
        "QuickTime Player",
        "QuickTime Player",
        "com.apple.quicktimeplayerx",
    ),
    (
        "Image Playground",
        "图乐园",
        "com.apple.generativeplaygroundapp",
    ),
    (
        "iPhone Mirroring",
        "iPhone 镜像",
        "com.apple.screencontinuity",
    ),
    ("Finder", "访达", "com.apple.finder"),
];

// These are present on a standard macOS CI image. Other apps can depend on
// the macOS release, hardware, or VM image and are tested whenever installed.
const REQUIRED_APPS: &[&str] = &[
    "Activity Monitor",
    "Disk Utility",
    "Finder",
    "Preview",
    "Terminal",
    "TextEdit",
];

// Match the maximum number of rows displayed by SpotlightBackend's unscoped query.
const RESULT_LIMIT: usize = 40;

#[test]
fn installed_system_apps_are_searchable_in_chinese_and_english() {
    let stock_paths = stock_app_inventory();
    let config = RuntimeConfig {
        app_scan_roots: vec!["/Applications".to_owned()],
        app_scan_depth: 1,
        localized_app_names: false,
        ..RuntimeConfig::default()
    };
    let (rows, worker) =
        discover_candidates_stream_scoped(&config, BootstrapScope::APPS_ONLY).into_parts();
    let candidates: Vec<_> = rows.into_iter().collect();
    worker.join().expect("application discovery worker");

    let mut indexed_paths: HashMap<PathBuf, HashSet<String>> = HashMap::new();
    for candidate in &candidates {
        if candidate.kind == CandidateKind::App
            && candidate.id.starts_with(CandidateIdKind::PREFIX_APP)
            && let Ok(path) = fs::canonicalize(candidate.path.as_ref())
        {
            indexed_paths
                .entry(path)
                .or_default()
                .insert(candidate.title.to_string());
        }
    }
    let engine = QueryEngine::new_with_config(candidates, &config);
    let os_version = Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
        .unwrap_or_else(|_| "unknown".into());
    let mut failures = Vec::new();
    let mut tested = 0;

    for &(english, chinese, identity) in STOCK_APPS {
        let installed = stock_paths
            .iter()
            .filter(|(path, bundle_id)| {
                path.file_stem()
                    .and_then(|stem| stem.to_str())
                    .is_some_and(|stem| stem.eq_ignore_ascii_case(english))
                    || bundle_id.as_deref() == Some(identity)
            })
            .map(|(path, _)| path)
            .collect::<HashSet<_>>();
        if installed.is_empty() {
            if REQUIRED_APPS.contains(&english) {
                failures.push(format!(
                    "{english}: required system bundle absent on macOS {os_version}"
                ));
            } else {
                eprintln!("ABSENT on macOS {os_version}: {english} ({identity})");
            }
            continue;
        }

        tested += 1;
        if !installed.iter().any(|path| {
            indexed_paths
                .get(*path)
                .is_some_and(|titles| titles.contains(chinese))
        }) {
            let found: Vec<_> = installed
                .iter()
                .map(|path| (path, indexed_paths.get(*path)))
                .collect();
            failures.push(format!(
                "{english}: expected visible title `{chinese}` for {found:?}"
            ));
        }

        let queries = if english == "Activity Monitor" {
            vec![english, chinese, "系统监视器"]
        } else if english == chinese {
            vec![english]
        } else {
            vec![english, chinese]
        };
        for query in queries {
            let rows = engine.search(query, RESULT_LIMIT);
            if !rows.iter().any(|row| {
                row.title == chinese
                    && row.id.starts_with(CandidateIdKind::PREFIX_APP)
                    && fs::canonicalize(&row.path).is_ok_and(|path| installed.contains(&path))
                    && matches!(&row.action, LaunchResultAction::Open { path } if path == &row.path)
            }) {
                let found: Vec<_> = rows.iter().map(|row| (&row.title, &row.path)).collect();
                failures.push(format!(
                    "{english}: `{query}` lacks expected bundle result; returned {found:?}"
                ));
            }
        }
        eprintln!("CHECKED on macOS {os_version}: {english} → {chinese}; {installed:?}");
    }

    eprintln!(
        "Checked {tested}/{} stock apps on macOS {os_version}",
        STOCK_APPS.len()
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Probe the runner independently of Lumio's scan roots and depth. Treat app
/// packages as leaves. Probe known shipped wrappers separately so their public
/// utility apps do not get mistaken for missing installations.
fn stock_app_inventory() -> HashMap<PathBuf, Option<String>> {
    let mut bundles = HashMap::new();
    for root in [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Library/CoreServices",
        "/System/Library/CoreServices/Finder.app/Contents/Applications",
        "/System/Library/CoreServices/VoiceOver.app/Contents/Resources",
    ] {
        collect_bundle_paths(Path::new(root), 4, &mut bundles);
    }
    bundles
}

fn collect_bundle_paths(path: &Path, depth: usize, bundles: &mut HashMap<PathBuf, Option<String>>) {
    if path.extension().is_some_and(|extension| extension == "app") {
        if let Ok(canonical) = fs::canonicalize(path)
            && canonical.is_dir()
        {
            bundles
                .entry(canonical.clone())
                .or_insert_with(|| bundle_identifier(&canonical));
        }
        return;
    }
    if depth == 0 || !path.is_dir() {
        return;
    }
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let child = entry.path();
            if kind.is_dir()
                || (kind.is_symlink()
                    && child
                        .extension()
                        .is_some_and(|extension| extension == "app"))
            {
                collect_bundle_paths(&child, depth - 1, bundles);
            }
        }
    }
}

fn bundle_identifier(path: &Path) -> Option<String> {
    let path = path.to_str()?;
    objc2::rc::autoreleasepool(|_| {
        NSBundle::bundleWithPath(&NSString::from_str(path))
            .and_then(|bundle| bundle.bundleIdentifier())
            .map(|identifier| identifier.to_string().to_ascii_lowercase())
    })
}

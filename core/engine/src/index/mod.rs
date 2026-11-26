use crate::BootstrapScope;
use crate::config::RuntimeConfig;
mod apps;
mod folders;
mod settings;

pub(crate) use folders::folder_candidate_id;
pub use folders::should_exclude_folder;
use lumio_indexing::{Candidate, CandidateIdKind};
use std::collections::HashSet;
use std::sync::mpsc;
use std::thread;

const INDEX_CHANNEL_CAPACITY: usize = 2048;

pub(super) const APP_CANDIDATE_ID_PREFIX: &str = CandidateIdKind::PREFIX_APP;
pub(super) const SETTINGS_CANDIDATE_ID_PREFIX: &str = CandidateIdKind::PREFIX_SETTING;

pub struct CandidateDiscoveryStream {
    pub rx: mpsc::Receiver<Candidate>,
    producer_handle: thread::JoinHandle<()>,
}

pub fn discover_candidates_stream(config: &RuntimeConfig) -> CandidateDiscoveryStream {
    discover_candidates_stream_scoped(config, BootstrapScope::ALL)
}

/// Like `discover_candidates_stream`, but only spawns the sub-discoveries selected
/// by `scope`. Sources whose flag is `false` are skipped entirely - no walker is
/// spawned and no candidates are emitted for them.
pub fn discover_candidates_stream_scoped(
    config: &RuntimeConfig,
    scope: BootstrapScope,
) -> CandidateDiscoveryStream {
    let (tx, rx) = mpsc::sync_channel(INDEX_CHANNEL_CAPACITY);
    let config = config.clone();
    let producer_handle = thread::spawn(move || {
        let folder_handle = if scope.folders {
            let folder_config = config.clone();
            let folder_tx = tx.clone();
            Some(thread::spawn(move || {
                folders::discover_folders(&folder_config, folder_tx);
            }))
        } else {
            None
        };

        if scope.apps {
            apps::discover_installed_apps(&config, tx.clone());
        }
        if scope.settings {
            settings::discover_system_settings_entries(config.localized_app_names, tx.clone());
        }
        drop(tx);

        if let Some(handle) = folder_handle
            && let Err(err) = handle.join()
        {
            eprintln!("lumio index: folder worker panicked: {err:?}");
        }
    });

    CandidateDiscoveryStream {
        rx,
        producer_handle,
    }
}

impl CandidateDiscoveryStream {
    pub fn into_parts(self) -> (mpsc::Receiver<Candidate>, thread::JoinHandle<()>) {
        (self.rx, self.producer_handle)
    }

    pub fn finish(self) {
        if let Err(err) = self.producer_handle.join() {
            eprintln!("lumio index: producer worker panicked: {err:?}");
        }
    }
}

pub fn discover_candidates(config: &RuntimeConfig) -> Vec<Candidate> {
    let (rx, producer_handle) = discover_candidates_stream(config).into_parts();
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    // Deduplicate centrally while receiving streamed candidates from all sources.
    for candidate in rx {
        if seen.insert(candidate.id.clone()) {
            out.push(candidate);
        }
    }

    if let Err(err) = producer_handle.join() {
        eprintln!("lumio index: producer worker panicked: {err:?}");
    }

    out
}

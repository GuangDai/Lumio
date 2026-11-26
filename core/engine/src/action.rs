use lumio_indexing::UsageAction;
use serde::{Deserialize, Serialize};
use std::str::FromStr;

const ACTION_OPEN_APP: &str = UsageAction::OPEN_APP;
const ACTION_OPEN_FOLDER: &str = UsageAction::OPEN_FOLDER;
const ACTION_OPEN_URL: &str = UsageAction::OPEN_URL;
const ACTION_REVEAL: &str = "reveal";
const ACTION_EXECUTE: &str = UsageAction::EXECUTE;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum ActionKind {
    OpenApp,
    OpenFolder,
    OpenUrl,
    RevealInFinder,
    ExecuteCommand,
}

impl ActionKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ActionKind::OpenApp => ACTION_OPEN_APP,
            ActionKind::OpenFolder => ACTION_OPEN_FOLDER,
            ActionKind::OpenUrl => ACTION_OPEN_URL,
            ActionKind::RevealInFinder => ACTION_REVEAL,
            ActionKind::ExecuteCommand => ACTION_EXECUTE,
        }
    }
}

impl FromStr for ActionKind {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            ACTION_OPEN_APP => Ok(ActionKind::OpenApp),
            ACTION_OPEN_FOLDER => Ok(ActionKind::OpenFolder),
            ACTION_OPEN_URL => Ok(ActionKind::OpenUrl),
            ACTION_REVEAL => Ok(ActionKind::RevealInFinder),
            ACTION_EXECUTE => Ok(ActionKind::ExecuteCommand),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LaunchAction {
    pub kind: ActionKind,
    pub target: String,
    pub metadata: Option<serde_json::Value>,
}

impl LaunchAction {
    pub fn open_app(path: &str) -> Self {
        Self {
            kind: ActionKind::OpenApp,
            target: path.to_string(),
            metadata: None,
        }
    }

    pub fn open_folder(path: &str) -> Self {
        Self {
            kind: ActionKind::OpenFolder,
            target: path.to_string(),
            metadata: None,
        }
    }

    pub fn open_url(url: &str) -> Self {
        Self {
            kind: ActionKind::OpenUrl,
            target: url.to_string(),
            metadata: None,
        }
    }
}

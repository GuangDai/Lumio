//! Recognizes URLs in launcher queries.

mod url;

pub use url::{UrlMatch, UrlTier, classify_url};

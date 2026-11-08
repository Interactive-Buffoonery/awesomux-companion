//! Offline companion to the pinned injector. Never opens a service or T3 store.
use anyhow::{Result, ensure};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ensure!(args.len() == 5, "usage: companion-inject APP CACHE LOG BUILD_ID METHOD");
    ensure!(squircle::overlay::eligible("Debug", false, &args[4]), "personal method required");
    let app = PathBuf::from(&args[0]);
    let info = plist::Value::from_file(app.join("Info.plist"))?;
    ensure!(personal_debug(&info), "app must carry the personal Debug marker");
    let cache = PathBuf::from(&args[1]);
    let log = PathBuf::from(&args[2]);
    let (_sender, cancel) = tokio::sync::watch::channel(false);
    let framework = squircle::overlay::framework(&cache, &log, cancel.clone()).await?;
    squircle::overlay::inject(&app, &framework, &args[3], &log, cancel).await
}

fn personal_debug(info: &plist::Value) -> bool {
    let Some(value) = info.as_dictionary().and_then(|d| d.get("AwesoMuxPersonalDebug")) else {
        return false;
    };
    value.as_boolean() == Some(true)
        || value.as_string().is_some_and(|s| matches!(s.to_ascii_uppercase().as_str(), "YES" | "TRUE"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_unmarked_or_release_apps() {
        for marker in [None, Some(plist::Value::Boolean(false)), Some(plist::Value::String("NO".into()))] {
            let mut dictionary = plist::Dictionary::new();
            if let Some(value) = marker { dictionary.insert("AwesoMuxPersonalDebug".into(), value); }
            assert!(!personal_debug(&plist::Value::Dictionary(dictionary)));
        }
    }
    #[test]
    fn accept_explicit_personal_debug_marker() {
        for value in [plist::Value::Boolean(true), plist::Value::String("YES".into())] {
            let mut dictionary = plist::Dictionary::new();
            dictionary.insert("AwesoMuxPersonalDebug".into(), value);
            assert!(personal_debug(&plist::Value::Dictionary(dictionary)));
        }
    }
}

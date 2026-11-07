//! Offline companion to the pinned injector. Never opens a service or T3 store.
use anyhow::{Result, ensure};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ensure!(args.len() == 5, "usage: companion-inject APP CACHE LOG BUILD_ID METHOD");
    ensure!(squircle::overlay::eligible("Debug", false, &args[4]), "personal method required");
    let app = PathBuf::from(&args[0]);
    let cache = PathBuf::from(&args[1]);
    let log = PathBuf::from(&args[2]);
    let (_sender, cancel) = tokio::sync::watch::channel(false);
    let framework = squircle::overlay::framework(&cache, &log, cancel.clone()).await?;
    squircle::overlay::inject(&app, &framework, &args[3], &log, cancel).await
}

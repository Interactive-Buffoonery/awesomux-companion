# Native foreground prototype

SwiftUI app, Swift 6, deployment target iOS 18+. Validated locally on iPhone 17 Pro Simulator with iOS 26.5 / Xcode 27. This is a Simulator development slice; physical devices, push, session discovery and launching new tasks are not implemented.

Regenerate the project from this folder with `xcodegen generate --spec project.yml`, then open `AwesoMuxCompanion.xcodeproj`. Select the AwesoMuxCompanion scheme and a local iPhone Simulator. Signing is disabled; no packages are required.

The app normally opens unconnected. To exercise a real managed thread, run `python3 bridge/launch_probe.py --interactive` from the workspace root. It creates a disposable authenticated server, verifies notification settings before inference, and prints only its private development-directory path. Copy that directory's `client.json` into the Simulator app data container at `Library/Application Support/development-client.json`, with mode 0600; never put the token in source or launch arguments. Restart the app after injection. This loading path exists only for debug Simulator builds.

Use the inbox row to open the thread, select or write all required answers, and submit once. Unknown outcomes remain locked; an explicit retry reuses the original operation bytes. A reconnect has a new generation and requires explicit acknowledgment if an earlier answer may have reached Codex. Secret questions and approval requests remain read-only.

The host accepts `next` for another question and `stop` for cleanup, with a 20-minute maximum lifetime. After testing, stop the host and trash the Simulator configuration. Xcode can migrate the app's data container during reinstall, so re-read the current container path before removing the file; do not rely on an earlier path.

Unit tests cover the wire fixtures, whole-control submission, races, failure states and bounded network receive. The separate UI integration test requires the injected disposable bridge configuration; it explicitly skips when none is present. Its exercised run passed without skips and verified actual background/resume with the pending question unchanged and no automatic answer. No ATS exception was needed on the tested Simulator; minimum-version network compatibility remains unverified.

Evidence and review reports are linked from [the native execution ledger](../docs/native-client-progress.md). Generated projects contain no development token. No paid hosted/native CI was run.

## Prepared phone pairing

The Connect a host sheet accepts a canonical private HTTPS origin on port 8443 or 10000 and a separate connection key. Credentials are held in Keychain on device and every Release build, with WhenUnlockedThisDeviceOnly accessibility and no synchronization. DEBUG Simulator pairing is in-memory; its existing private development file is used only when no paired item is present. Release artifacts exclude the development configuration and in-memory store.

Host changes immediately retire old controls and client identities. A failed save/delete/load disables the connection; activation cannot silently undo that failure. Explicit retry identifies the saved prior host and requires a fresh authenticated read. Late old-host GET/POST results cannot affect the replacement connection, even with identical server generation/control IDs. Disconnect suppresses implicit reload in this process until deliberate retry/pair; it does not revoke the host token. Keychain items can survive app uninstall, so uninstall alone is not credential cleanup.

26 unit tests currently pass, and an unsigned Release device build compiles the Keychain-only source path. Signing/provisioning, installation, physical HTTPS, Keychain runtime behavior and APNs remain unexercised. The prepared route and pending action boundaries are recorded in [the physical execution ledger](../docs/physical-foreground-progress.md).

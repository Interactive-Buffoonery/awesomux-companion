# awesoMux Companion

A read-only iPhone companion for awesoMux: which agents need you, are working,
or are done, shown in the app, a widget, a Live Activity, and notifications.
Built from eD!'s awesomux-ios project.

- [`CONTRACT.md`](CONTRACT.md): relay and push contract; change it first.
- [`relay/`](relay/): Mac relay over the awesoMux local agent API.
  Tests: `python3 -m unittest discover -s relay`.
- [`ios/`](ios/README.md): SwiftUI app and widget extension.

Phase 1 runs in the Simulator with `simctl push`. Phase 2 adds APNs, a physical
device, and Tailscale HTTPS pairing.

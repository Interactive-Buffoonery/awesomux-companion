# awesoMux Companion

A read-only iPhone companion for awesoMux: which agents need you, are working,
or are done, shown in the app, a widget, a Live Activity, and notifications.
Built from eD!'s awesomux-ios project.

- [`ios/`](ios/README.md): SwiftUI app and widget extension.

The phone pairs directly with awesoMux on the Mac (Settings → awesoMux
Companion → Pair iPhone) and reads its agents over mutual TLS. The wire
contract lives in the awesoMux repository at
`docs/companion-pairing-protocol.md`.

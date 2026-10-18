# awesoMux Companion

A read-only iPhone companion for awesoMux: which agents need you, are working,
or are done, shown in the app, a widget, a Live Activity, and notifications.
Built from eD!'s awesomux-ios project.

- [`ios/`](ios/README.md): SwiftUI app and widget extension.

The phone pairs directly with awesoMux on the Mac (Settings → awesoMux
Companion → Pair iPhone) and reads its agents over mutual TLS. The wire
contract lives in the awesoMux repository at
`docs/companion-pairing-protocol.md`.

The shared `AwesoMuxCompanionProtocol` package will live at this repository's
root. The Mac will pin a tagged release; the phone will use the same checkout.
See [ADR-0001](docs/adr/0001-shared-companion-protocol-package.md) for the decision
and version-pinning policy. Extraction and migration are follow-up work.

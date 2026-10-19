# awesoMux Companion

A read-only iPhone companion for awesoMux: which agents need you, are working,
or are done, shown in the app, a widget, a Live Activity, and notifications.
Built from eD!'s awesomux-ios project.

- [`ios/`](ios/README.md): SwiftUI app and widget extension.

The phone pairs directly with awesoMux on the Mac (Settings → awesoMux
Companion → Pair iPhone) and reads its agents over mutual TLS. The wire
contract lives in the awesoMux repository at
`docs/companion-pairing-protocol.md`.

The root `AwesoMuxCompanionProtocol` Swift package holds v1 wire types, framing,
pairing links, and confirmation words (Swift 6, iOS 26, macOS 15). Run `swift test`
at the root. Contract fixtures follow the Mac protocol document; unknown response
strings, optional phone metadata, fractional ISO dates, and UUID case remain
compatible. TLS, credentials, authorization, and display policy stay in the apps.

The phone uses the local package through `ios/project.yml`. The Mac pins an exact
package release and commits `Package.resolved`; plain semantic-version tags are
reserved for the package. See [ADR-0001](docs/adr/0001-shared-companion-protocol-package.md).

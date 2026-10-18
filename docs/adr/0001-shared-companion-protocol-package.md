# ADR-0001: Keep the shared protocol in the Companion repository

Date: 2026-10-18

Status: Decided; package creation and consumer migration remain follow-up work.

Issue: [awesomux-companion #6](https://github.com/Interactive-Buffoonery/awesomux-companion/issues/6)

## Decision

Keep the shared source in this MIT-licensed repository,
`Interactive-Buffoonery/awesomux-companion`. Add a root `Package.swift` exposing
one library product/module named `AwesoMuxCompanionProtocol`, with explicit
source and test directories at `Sources/AwesoMuxCompanionProtocol/` and
`Tests/AwesoMuxCompanionProtocolTests/`. The manifest must build only the shared
package, without pulling in the iOS app, diagnostics, or renderer dependencies.
The maintainers of the Mac and Companion apps jointly own its contract and
releases. Changes affecting either consumer require review against both.

The Mac consumes tagged releases from this repository through SwiftPM. The
phone consumes the root package locally from the same checkout. Its app commit
pins the protocol source it builds. Both use one implementation of the shared
wire contract.

The protocol package is suitable for public distribution under the existing
MIT license, preserving applicable attribution. Runtime private keys, pairing
secrets, credentials, and captured user data are not package contents. Keeping
the package here does not require changing this repository's visibility.

## Context and alternatives

The phone currently defines `MacClient.Request`, `MacClient.PairReply`, and
`APIResponse` in `ios/AwesoMuxCompanion/MacClient.swift`. It also implements
length-prefixed framing and pairing-word derivation there. The Mac defines
`LocalAPIRequest` and `LocalAPIResponse` in
`Sources/AwesoMuxLocalAPI/LocalAPIContract.swift`, framing in its API transport
and Companion listener, and pairing behavior in
`Sources/awesoMux/Services/CompanionPairingCoordinator.swift`.

The existing Mac `AwesoMuxLocalAPI` target also includes Darwin socket/server
code. The Mac package contains the app, Ghostty integration, and unrelated
dependencies. The phone's `ios/project.yml` currently has no shared protocol
dependency. Importing the Mac API target is therefore not the desired portable
contract boundary.

- **Companion repository (chosen):** a root package gives the Mac a portable
  library and lets the phone reuse its own checkout. It avoids a third repository
  and keeps contract changes beside the phone consumer. Protocol tags share this
  repository's history, but their version numbers are independent of app versions.
  The Mac clones this repository to resolve the package; it builds only the
  selected library and its dependencies.
- **Mac repository:** keeps extraction close to today's authoritative producer,
  but makes the phone consume the Mac repository's manifest and release history.
  A nested package alone does not provide an independently versioned root
  package for ordinary SwiftPM URL dependencies.
- **Dedicated repository:** gives the protocol an independent release history,
  but adds another repository and coordination overhead for two closely related
  consumers. Revisit extraction if more consumers or release needs justify it.

## What belongs in the package

- Codable/Sendable wire requests, responses, payloads, and version identifiers,
  including pairing messages and the existing Companion API subset.
- Pairing-link parsing/building and format validation; choosing a network
  interface and deciding which addresses to advertise remain app responsibilities.
- A pure four-byte big-endian framing codec and protocol size limits. Socket
  reads, timeouts, cancellation, and connection lifecycle stay in each app.
- Pairing-word derivation and its single 256-word table, compiled into the
  package as Swift data. Preserve the documented word-list hash and test vectors.
  This avoids resource-bundle lookup in the Mac's manually assembled app bundle.
- Wire-format documentation and shared fixtures, including the existing
  pairing test vectors, JSON encoding rules, and framing boundary cases.

Use only the portable platform APIs needed for these contracts, initially
Foundation and CryptoKit. Support the consumers' current iOS 18 and macOS 15
deployment floors. Choose and verify the package's minimum Swift tools version
against both consumer toolchains during extraction; do not inherit the Mac
app's toolchain requirement without checking the phone build.

Keep Network/TLS setup, identities, Keychain access, grant persistence,
authorization, rate limits, UI, App Group snapshots, WidgetKit/ActivityKit,
terminal rendering, and zmx integration in their existing owners. Sharing an
operation name never grants permission to invoke it: the Mac listener retains
its operation allowlist and argument checks.

Extract the common wire values once and let the Mac local API reuse them.
Keep local bearer-credential requests and context-only fields in Mac-owned
wrappers where needed. Do not move the entire local API into this package.
Companion requests must preserve their existing ability
to omit `profile` and must not acquire a bearer `credential` requirement.
Preserve unknown operation/error strings until the appropriate validator can
handle them; a closed Swift enum must not accidentally break forward decoding.
Remove duplicated DTOs, codecs, and word lists when each consumer migrates.

The Mac's `docs/companion-pairing-protocol.md` remains authoritative until the
extraction moves shared wire documentation and fixtures into this repository.
After that move, the Mac document links to the package contract and retains
host-specific behavior. Change shared documentation beside its implementation.

## How each side pins and updates

Start with an immutable `0.1.0` tag in this repository after the existing wire-v1
extraction passes verification. This number is a planned first protocol release,
not an available version. Reserve plain semantic-version tags for the root
package; use a separate naming convention for any app-only release tags. The
phone's marketing/build numbers remain independent. Never move or reuse a
published tag.

- **Mac:** declare `https://github.com/Interactive-Buffoonery/awesomux-companion.git`
  with an exact version requirement in root
  `Package.swift`'s macOS branch, add the product to the targets that use it,
  and commit root `Package.resolved`, including the resolved Git revision.
- **Phone:** declare the root package as a local dependency at `..`, relative
  to `ios/project.yml`, and add its product to the app and any target that
  directly imports it. The app's Git commit pins both app and package source
  atomically; do not fetch a second remote copy of this repository. A local
  package has no separate version pin in `Package.resolved`. The widget only
  needs the dependency if it directly imports package types.

The initial package has no third-party dependencies. If it gains remote
dependencies, commit the root package's `Package.resolved` for package CI and
the phone app's resolution at
`ios/AwesoMuxCompanion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The latter directory is currently ignored wholesale by `ios/.gitignore`; narrow
that rule when the lockfile is needed and verify XcodeGen regeneration preserves
it. The Mac owns its complete resolution because a dependency's lockfile does
not control the consuming application's resolution.

Release and CI builds must honor the committed resolutions and app source
revision. Do not use remote branch dependencies or automatic version ranges.
The phone's checked-in local reference to this repository's root is intentional;
cross-checkout overrides on the Mac are temporary development conveniences and
must not enter its release configuration.

For an update, review the package and phone adaptation together in this
repository, verify both consumers, then tag the package release. Submit a
separate pin-and-lockfile change to the Mac. The person changing the contract
owns coordinating those changes and their compatibility evidence. App
maintainers own merging and shipping their respective updates; deployment need
not be simultaneous. Roll back the Mac by restoring its previous exact
requirement and lockfile; roll back the phone using the app/package source
revision that produced the previous build.
For a new wire format, ship Mac support for both old and new formats before the
phone starts using the new one. The phone must still handle an older Mac through
an existing compatible format or an explicit unsupported result. Define the
supported version window before removing an old format; never assume installed
apps updated together.

## Package versions and wire compatibility

Package semantic versions describe the Swift source API; pairing-link `v`,
pairing-message `v`, API `schemaVersion`, and future stream versions describe
wire formats. Changing the package version alone changes none of those fields.
During `0.x`, use a new minor release for source-breaking changes and patches
for compatible fixes. From `1.0.0`, use normal semantic versioning.

The initial extraction preserves today's bytes, validation, and wire v1,
including `unpair`, optional fields, UUID/date handling, error envelopes, and
frame limits. No new scope, route, stream, or capability is introduced here.
All three current version fields remain `1` in the initial release. The planned
v2 pairing link belongs to a subsequent contract change and release.
An older installed phone must continue to work with a newer Mac supporting its
wire version, even when their bundled protocol revisions differ.

Additive fields must tolerate absence and unknown keys where the contract
permits. Future capabilities require explicit advertisement/negotiation before
use; an unsupported operation must stay unsupported. Incompatible wire changes
require an explicit wire version and a documented compatibility/rollout policy.
A package major bump by itself cannot make independently installed apps safe.

## Follow-up implementation and evidence

This ADR completes the placement and pinning decision in #6. It does not
implement or verify extraction. The implementation must:

1. Add the root manifest, shared source/test directories, documentation, and
   package CI here, using the existing license and preserving attribution.
2. Extract the existing contracts without changing behavior and check the shared
   pairing vectors, JSON fixtures, malformed/oversized frames, partial frames,
   date formats, and omitted optional fields against both existing consumers.
   Verify actual Mac local-API encodings decode through the shared Companion
   types, including unknown strings and the phone's fractional-date tolerance.
3. Integrate the phone through the local root package, publish the first immutable
   protocol tag here, then migrate the Mac with an exact pin and tracked lockfile.
   Preserve Mac-only local API behavior and remove the
   phone's duplicate wire definitions and framing logic. Remove both apps'
   duplicate word files and their resource-copy/build-script entries once the
   compiled table is adopted.
4. Prove fresh-checkout resolution/builds for both apps, including XcodeGen
   regeneration, and rerun the real pairing, roster, attention, and unpair flows.
   Record the app commits and package revision. Check old/new consumer pairs
   before shipping independently; a package-only test pass is insufficient.

## Decision evidence

Reviewed Companion `main` at `eb1794bd2ebef737d9552c2ee8b2cf0cbdfe8ce7`
and the Mac checkout at `2a0b46bf20576da64f7f5035bdea256ddb147743`.
The [architecture plan](https://awesomux-planning.space.fast/plan.html#arch)
and its M0 section call for shared contract types, framing, pairing-word
derivation, and test vectors. The live URL returned HTTP 403 to `curl`; the
local planning source at
`awesomux-mobile-directions/walkthrough/plan.html` supplied that context.

SwiftPM's [dependency guidance](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/Dependencies/AddingDependencies.md),
[release guidance](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/ReleasingPublishingAPackage.md),
and [resolution guidance](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/ResolvingPackageVersions.md)
describe version requirements, tags, and resolved dependency state. Exact
requirements plus the Mac's committed lockfile pin the remote consumer. The
phone's app commit pins its local protocol source; lockfiles pin any future
remote dependencies.

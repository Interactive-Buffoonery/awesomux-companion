# ADR-0001: Give the shared Companion protocol its own package

Date: 2026-10-18

Status: Decided; package creation and consumer migration remain follow-up work.

Issue: [awesomux-companion #6](https://github.com/Interactive-Buffoonery/awesomux-companion/issues/6)

## Decision

Put the shared source in a dedicated MIT-licensed repository,
`Interactive-Buffoonery/awesomux-companion-protocol`, with a root `Package.swift`
and one library product/module named `AwesoMuxCompanionProtocol`. This is the
chosen repository name, not a claim that the repository or a release exists.
The maintainers of the Mac and Companion apps jointly own its contract and
releases. Changes affecting either consumer require review against both.

Both apps consume tagged releases of that package through SwiftPM. Neither
app repository owns a second implementation of the shared wire contract.

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

- **Companion repository:** a root package could avoid a new repository, but
  protocol tags and releases would share the phone app's history and lifecycle.
  The Mac would depend on the phone repository to implement its own API.
- **Mac repository:** keeps extraction close to today's authoritative producer,
  but makes the phone consume the Mac repository's manifest and release history.
  A nested package alone does not provide an independently versioned root
  package for ordinary SwiftPM URL dependencies.
- **Dedicated package (chosen):** gives both consumers the same small dependency
  with independent releases. The cost is a third repository, its CI, and explicit
  dependency-update PRs in both apps. That cost is justified by the existing
  duplication and the plan's future streaming contracts.

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
extraction moves shared wire documentation and fixtures into the new package.
After that move, the Mac document links to the package contract and retains
host-specific behavior. Change shared documentation beside its implementation.

## How each side pins and updates

Start with an immutable `0.1.0` tag after the existing wire-v1 extraction passes
verification. This number is a planned first release, not an available version.
Never move or reuse a published tag.

- **Mac:** declare the package URL with an exact version requirement in root
  `Package.swift`'s macOS branch, add the product to the targets that use it,
  and commit root `Package.resolved`, including the resolved Git revision.
- **Phone:** declare the same URL and exact version in `ios/project.yml`, add
  the product to the app and any target that directly imports it, and commit
  `ios/AwesoMuxCompanion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  The generated project is currently ignored wholesale by `ios/.gitignore`;
  migration must narrow that rule to track this lockfile while leaving generated
  project files ignored. Verify regeneration and a clean checkout preserve the
  lockfile. The widget only needs the dependency if it directly imports package
  types.

Release and CI builds must honor the committed resolutions and fail if they
require a different resolution. Do not use branch dependencies, automatic
version ranges, or sibling path overrides in committed release configuration.
Temporary local overrides are development conveniences only.

For an update, release the package first, then submit a separate pin-and-lockfile
change to each app. The person changing the contract owns coordinating both
updates and their compatibility evidence. App maintainers own merging and
shipping their respective updates; deployment need not be simultaneous. Roll
back a consumer by restoring its previous exact requirement and lockfile.
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
wire version, even when their package pins differ.

Additive fields must tolerate absence and unknown keys where the contract
permits. Future capabilities require explicit advertisement/negotiation before
use; an unsupported operation must stay unsupported. Incompatible wire changes
require an explicit wire version and a documented compatibility/rollout policy.
A package major bump by itself cannot make independently installed apps safe.

## Follow-up implementation and evidence

This ADR completes the placement and pinning decision in #6. It does not
implement or verify extraction. The implementation must:

1. Create the package repository, license, root manifest, documentation, and CI.
2. Extract the existing contracts without changing behavior and check the shared
   pairing vectors, JSON fixtures, malformed/oversized frames, partial frames,
   date formats, and omitted optional fields against both existing consumers.
   Verify actual Mac local-API encodings decode through the shared Companion
   types, including unknown strings and the phone's fractional-date tolerance.
3. Publish the first immutable release, then migrate both apps with exact pins
   and tracked lockfiles. Preserve Mac-only local API behavior and remove the
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
requirements plus committed app lockfiles are the release policy selected here.

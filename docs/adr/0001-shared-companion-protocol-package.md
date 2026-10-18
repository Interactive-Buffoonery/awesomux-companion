# ADR-0001: Keep the shared protocol in this repository

Status: Decided

Issue: [#6](https://github.com/Interactive-Buffoonery/awesomux-companion/issues/6)

## Decision

Add a root Swift package named `AwesoMuxCompanionProtocol` to `awesomux-companion`.

It will hold the shared request and response types, framing codec, pairing-link
format, and pairing-word derivation. Networking, credentials, authorization, and
UI stay in the apps.

## Why here

The Mac and phone currently duplicate parts of the protocol. Keeping the package
here removes that duplication without adding another repository.

A root package lets the Mac build the shared library without building the iOS
app. A separate repository would give it an independent release history, but we
don’t need that yet.

## Versioning

The phone uses the local package from the same checkout. Its app commit pins the
protocol source.

The Mac depends on this repository through SwiftPM, using an exact release tag
and a committed `Package.resolved`. Reserve plain semantic-version tags for
protocol releases; app versions remain separate.

Package versions and wire versions are independent. The initial extraction
preserves the existing wire format so either app can update without requiring
the other to update at the same time.

## Next step

Extract the shared code, connect both consumers, and verify pairing and API
compatibility before publishing the first package release.

# Pending decisions (direct paired transport)

`list_pending_decisions` requires a separate Mac-approved Decide switch for
the phone, which covers every workspace. It returns `pendingDecisions`, fresh retained
`decisionOutcomes`, and `remoteDecisionsEnabled`. A disabled provider/version
returns no actionable requests. Pairing and status access never enable Decide.
The native-prompt race release gate is independent of transport fixture tests.

`decide` carries `decisionAnswer`: the full Mac-issued identity,
`choice` (`allow` or `deny`, once only), a UUID `retryID`, and an optional
`note` for Claude. A note is allowed only with `deny`, must contain visible
text, and is at most 500 Unicode scalars; decoding rejects anything else. Identity binds
runtime, workspace, pane, target version, provider session, invocation and
revision. Never synthesize a replacement identity or queue an offline answer.
Both operations use the existing authenticated direct LAN/Tailscale connection.
There is no bearer, relay, notification or terminal-input authority.

`decisionReceipt` is the original stable retry receipt. Retry IDs bind the
authenticated device, exact identity, choice and note; conflicting reuse fails.
Use `decisionOutcomes` from a fresh list to learn later delivery state.
`recorded` confirms a core commit; `delivered` confirms hook acknowledgement,
never provider execution. Losing answers cannot overwrite the winning source.
Unknown/evicted identities cannot become pending again.

The remote deadline is fixed at issuance, at most 60 seconds and shorter than
the helper lifetime with a return reserve. Remote expiry leaves the local Mac
window intact. Outcomes and retries remain bounded through hook expiry plus
ten minutes; exhaustion refuses work. Revalidate current workspace assignment,
identity, device grant and lease before commit and each actual hook write.

Optional response decision fields tolerate future values: if any element of
`pendingDecisions` or `decisionOutcomes`, or the `decisionReceipt`, cannot be
decoded, that entire optional field is omitted (`nil`). Other status, agent and
pane fields survive. Never act on a partly decoded decision or unknown choice.
Decision enums and incoming `CompanionDecisionAnswer` decoding remain strict.

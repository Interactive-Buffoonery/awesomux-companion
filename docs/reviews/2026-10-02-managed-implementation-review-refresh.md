# Managed probe implementation review refresh

2026-10-02. Reviewer adapter: Codex collaboration subagent, configured model **gpt-6-astra**, high reasoning, fresh review context per parent dispatch metadata. This is an actual refreshed review of the files hashed below, not a relabeling of the earlier report.

## Verdict

**No blocking findings remain for this disposable feasibility probe.** The revised code and documentation address the prior endpoint, malformed-input, teardown, and evidence-claim findings. This verdict does not certify a production bridge or full companion readiness.

## Scope and impact

Prior scope: `docs/reviews/2026-10-02-managed-final-scope.json`, reviewed in the preceding implementation report. Current source and documentation were read again. The new runtime helper and its tests were included. All changed validation, cleanup, routing, and claim surfaces received a fresh pass; the unchanged WebSocket helper and retained live result were also inspected. The old scope manifest remains historical.

| File | Current SHA-256 | Relative to prior manifest |
| --- | --- | --- |
| `probes/codex_control_probe.py` | `e49c9d3e420c304d53bac82e4c0272a2d05b40d893b8493630296321d139e8ce` | changed |
| `probes/test_codex_control_probe.py` | `54091b1060ec628cbda786e2619958eab738c9553447b5965155651226c826b8` | changed |
| `probes/probe_runtime.py` | `d017197f73b0146e29075f8a8999799f2096991750f1650db1ac4ff7b05527c9` | new |
| `probes/test_probe_runtime.py` | `97f18f221b2848d2a0c5b74a6e07c6164c315ebea3c30fa04561897412b47a27` | new |
| `probes/run_live_probe.py` | `9f3c87e14f03c00e0755d3ef6ad74a5bc63b3f53f3386965f5f76418d95c5fd5` | changed |
| `probes/ws_proxy.mjs` | `220a6f1b15b7fa01fe4e98c7fa24b7a603f77934f6f11a7e9fd510149a3fb1e6` | unchanged |
| `docs/codex-live-control-findings.md` | `1c2208bd72592b00b0958305ede9dfe29b07a8ba0e274e431ec9ceffb1b29da8` | changed |
| `docs/companion-v1-design.md` | `656fe42f5aff93e199959f30f66f48e1d2691b13e8899ac84092b881a1b6498d` | changed |
| `docs/reviews/2026-10-02-managed-live-final-result.json` | `7d62b7020c585e9f64e61c7bba2d8a7b1b865bbd12934237482dcb181f2bf84a` | unchanged |

## Findings resolved

- Endpoint validation parses the authority, rejects userinfo and non-loopback destinations, and stays active under Python optimization.
- The local guard ignores malformed containers and resolution IDs, rejects malformed question options and unsupported answer shapes, and keeps old-incarnation/repeated replies from writing.
- Teardown attempts peers, amx, desktop, and PTY independently. A failed amx listing leaves absence unknown, and uncertain teardown retains the owned session name.
- The runner now filters requests, deltas, completion, and resolution by owned identities and retains event multiplicity. Historical prose claims an observed completion, not measured exactly-once continuation.
- The pre-answer VT drain now has a four-second monotonic deadline.
- Historical inspection statements are labeled as historical. The reproduction instructions explicitly require scrubbing routing variables from the separate server environment as well as the runner's subprocesses.

## Checks performed

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s probes -p 'test_*.py'`: 5 tests passed.
- The same command under `python3 -O`: 5 tests passed.
- Parsed all probe Python files and executed focused checks of the current `same_turn` predicate: matching direct/nested turn IDs accepted; foreign thread and wrong turn rejected.
- Read the final VT deadline change and final documentation after the focused checks. No runtime server, daemon, model inference, or existing conversation was contacted during review.

## Remaining limits, not blockers for this scope

The retained live result belongs to the earlier runner; no live rerun of the hardened code is claimed. The original server environment scrub is reported by the executor but lacks an independently inspectable launch artifact. Historical events do not prove event multiplicity or exhaustive server-wide arbitration. Existing-session takeover, exact desktop prompt disabling, desktop-first response, live lost acknowledgement, restart behavior, hook registration, phone-facing authentication, and push remain unexercised or outside this probe.

The caller must still select an owned disposable loopback server and stop it afterward; URL validation cannot establish process ownership. These constraints are documented, and this review does not authorize connecting to shared runtimes.

## Declined to judge

- Production bridge architecture, persistent outcome storage, and mobile transport security: no such product implementation is in this contribution.
- Physical-device push and exact desktop prompt state: explicitly outside the captured evidence.
- Retrospective proof of server environment scrubbing: the missing provenance is disclosed and cannot be recreated by relabeling present files.

Only this review report was written by the reviewer. No product files were mutated.

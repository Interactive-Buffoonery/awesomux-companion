# awesoMux iOS companion

The current approved direction is a small Codex-first companion: session threads, actionable questions and notifications, and new tasks in configured projects. No terminal or break reminders in the first scope.

- [Approved design](docs/companion-v1-design.md)
- [Verified live-control findings](docs/codex-live-control-findings.md)
- [Foreground bridge contract and setup](bridge/README.md)
- [Native client setup](ios/README.md)
- [Native validation ledger](docs/native-client-progress.md)

The native SwiftUI Simulator app and authenticated foreground bridge now show a real managed Codex thread, submit a question answer and display its completed response. Local tests exercise uncertainty, reconnect identity, transport limits and background/resume. Plans received plan review and Claude Opus 5.5 adversarial review; implementation received independent review with concrete fixes. Physical-device pairing, push, ordinary-session discovery and new-session creation remain unfinished. This local folder is not a Git repository; no publication has occurred.

The September research below is historical and its terminal-first recommendation is superseded by the approved companion design.

---

# September exploration: iPhone and iPad

**A real remote terminal and an awesoMux workspace that follows you between devices.**

Product exploration · 2026-09-07 · proposals for discussion, not an approved implementation specification.

The strongest direction is a native iPhone/iPad peer to awesoMux: recognize the project you left open, understand what changed, review the work, and continue in the same terminal session. iPhone should make short interventions comfortable; iPad should support sustained remote development.

This is a competitive market. Agent notifications and a chat screen are already available elsewhere. The opportunity to test is whether awesoMux can make the **whole workspace**—terminals, agents, plans, changes, and device handoff—feel substantially more coherent.

## Read this in order

| Document | What it answers |
| --- | --- |
| [Product direction](docs/product-direction.md) | Who this is for, why it should exist, phone versus tablet, and the first useful release |
| [Competition and quality bar](docs/competition-and-quality.md) | What Moshi and Blink already do, where differentiation is plausible, and how to test parity |
| [Technical feasibility](docs/technical-feasibility.md) | What awesoMux already owns, what needs building, architecture alternatives, and corrections to earlier planning |
| [Business and validation](docs/business-and-validation.md) | Positioning, pricing experiments, sustainable revenue arithmetic, and a career-pivot evidence path |

## Working recommendations

- Build toward a full terminal peer. A dashboard is a useful development milestone, but an insufficient launch proposition by itself.
- Prove one complete Mac → phone → iPad → Mac workflow before expanding the feature inventory.
- Keep sessions on a reachable host; treat mobile disconnect and reconnect as ordinary behavior.
- Start with bring-your-own machines and direct SSH connectivity. Validate whether richer workspace access needs a persistent host service before committing to a new network stack.
- Sell a useful professional product. Hosting push messages is an operating responsibility, not a defensible business by itself.

## Status and provenance

The folder contains documentation only. No app, dependencies, host service, remote repository, or tracker issues were created. No runtime benchmarks or competitor hands-on tests were performed. Competitor descriptions are dated readings of primary documentation; proposed targets are explicitly unmeasured.

Sources include the public awesoMux checkout at `c30c2ec37b540605427f368aa057c791f2e1d742`, private planning in `awesomux-internal`, the archived `awesomux-private` predecessor, and relevant JiggyBrain notes. The [technical document](docs/technical-feasibility.md#research-provenance-and-corrections) records the differences between earlier ideas and current evidence.

**Private working material:** these documents link to private planning and include founder/business discussion. Prepare a separate public brief when publication is wanted.

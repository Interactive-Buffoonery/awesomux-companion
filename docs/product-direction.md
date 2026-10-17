# Product direction

2026-09-07 · proposed direction · read with [competition](competition-and-quality.md) and [feasibility](technical-feasibility.md).

## The product in one sentence

**Pick up your development workspace on whichever device is in your hand, with enough context to make a good decision and a real terminal to carry it out.**

The customer buys fewer interruptions and less reconstruction of context. The terminal, status indicators, and review tools serve that outcome.

Working assumption: both iPhone and iPad matter, with different interaction priorities. This follows eD!'s July 24 preference for a full terminal rather than a permission-card-only companion. An optional question was raised in this session; no new preference has been submitted yet. These recommendations are editable, not ratified decisions.

## Three possible products

| Approach | What is attractive | What makes it hard | Recommendation |
| --- | --- | --- | --- |
| Agent check-in companion | Small UI; a clear away-from-desk use case | Heavy overlap with Moshi and provider-owned remote controls; insufficient for terminal work | Useful internal milestone |
| General professional SSH terminal | Broad usefulness without desktop adoption | Years of keyboard, network, file, and compatibility expectations; weak reason to switch from Blink | Essential capability, broad parity grows over time |
| Full awesoMux workspace peer | Builds on the desktop's session organization and review workflow; useful on both phone and tablet | Needs stable host identity, metadata, reconnect, and simultaneous-client semantics | Recommended product direction |

The third option contains a good terminal. It must not hide an unreliable terminal behind attractive cards. Conversely, matching every historical Blink feature before showing a coherent workspace would postpone learning for too long.

## First customer

A developer already running coding agents and terminal workflows on a Mac or Linux host, frequently switching between projects, who wants to finish a small intervention away from the desk and occasionally work seriously on an iPad.

Existing awesoMux users are the most reachable initial cohort. A supported Linux host should eventually work without purchasing or running the Mac GUI. Initial validation can be Mac-first, but requiring a Mac forever would cap the audience and weaken the remote-work story.

Do not start with enterprise fleets, managed cloud compute, arbitrary team permissions, or people expecting a local Xcode replacement. Those are separate customer problems.

## The signature workflow

1. Start a task in awesoMux on the Mac. The workspace has an agent terminal, a plan, and a running check.
2. Leave the desk. The phone shows one useful alert when a decision is needed, respecting the user's quiet settings.
3. Open the alert into the exact host, workspace, pane, and pending request. See what changed and whether the state is current.
4. Read the relevant plan paragraph or diff. Respond with enough evidence to understand what the action permits. If a structured response is unsupported, open the actual terminal.
5. On iPad, open the same workspace with a hardware keyboard. Read the plan beside the terminal, edit through the remote tools, and run a check.
6. Return to the Mac. The existing session continues; approvals are resolved, artifacts reflect the host's latest versions, and device layout preferences remain sensible.

That entire loop is the product demo. A grid of green status dots is not sufficient evidence that it works.

## iPhone: short, confident interventions

Default surface: recent/pinned workspaces with a clearly labeled **Needs you** group. Working sessions remain accessible without taking over the screen. Include host identity and last-updated information; use text and symbols alongside color.

A workspace opens a readable activity or review surface with the terminal one tap away. Start with structured events and existing transcript data; do not add an LLM dependency just to produce a summary. A concise “since you last looked” view is a hypothesis to test, especially because competitors already offer similar recaps.

Software input needs Esc, Tab, Ctrl, arrows, paste, and an editable multiline composer. Dictation produces a draft; sending remains deliberate. Selecting output must not accidentally type into the shell. A screenshot attachment should show its destination before upload.

Example: while out with Rocket, read a question, inspect the relevant change, send one response, and put the phone away. Success is getting back to the walk—not making the phone a permanent incident console.

## iPad: sustained work

Use the available width for a familiar workspace sidebar, the active terminal, and a document or diff beside it. Collapse intelligently in narrow windows. A single terminal needs to be excellent before more simultaneous terminal panes are added.

Hardware keyboard, pointer, selection, and focus recovery are core product work. Support predictable shortcuts and discoverability; do not require remembering touch gestures for ordinary commands. Tablet windows and external displays need their own state, rather than copying desktop pixel layouts.

Suggested first serious work session: connect, navigate a project, run the agent, inspect a plan and diff, use a remote editor, upload a file from Files, preview a local web server, leave the app, and return successfully. Native code editing can wait while remote terminal editors cover this job. A hosted web editor can be evaluated later, with its own keyboard and security costs.

## What should follow you

| Shared meaning | Device-local presentation |
| --- | --- |
| Host, workspace, pane, backend session, provider session identities | Window positions and pane proportions |
| Workspace names, ordering, associations, pinned project intent | Font size and software-keyboard toolbar |
| Agent events and current pending request | Scroll position and temporarily focused view |
| Authoritative plan/diff resource identity and revision | Expanded cards and local draft responses |
| Which decisions are already resolved | Quiet settings unless explicitly synchronized |

Persisted UI organization, live process state, and credential synchronization are three separate concerns. Syncing a sidebar file cannot move a running process between machines.

## The plausible advantage

awesoMux already knows about workspace groups, terminal panes, execution locations, agent identity, and document review. The proposed advantage is making that context useful across devices with little configuration.

The strongest specific angle is **reviewing and steering work in its existing workspace**: understand the plan, inspect the change, leave anchored feedback, continue in the terminal, then come back to the same artifacts on the Mac. File-backed annotations provide a concrete starting point. Remote editable review is still new work; the desktop's current remote Markdown surface is a read-only snapshot.

Other promising qualities are an uncluttered native iPad experience, explicit device control of terminal size, and notification policies that reduce distraction. These are execution hypotheses, not exclusive features or a claim that competitors cannot copy them.

The competitive document deliberately separates demonstrated capabilities from candidate advantages. No “first,” “only,” “fastest,” or “unique” marketing claim is supported by this research.

## A first useful release versus the eventual product

| Milestone | Must demonstrate | Explicit limit |
| --- | --- | --- |
| Internal vertical slice | One known host, real durable terminal, reliable foreground reconnect, correct session identity on phone and tablet | No commercial parity claim |
| Private dogfood | Workspace list and state, safe response path, locked-device push, hardware-keyboard work, one read-only artifact surface | May support one agent deeply; other agents retain terminal access |
| Narrow paid beta candidate | Complete signature workflow, remote session creation, documented supported hosts, usable attachments and preview, direct recovery path | Supported subset is explicit; no broad Blink replacement claim |
| Daily-driver release | Quality gates in the competition document, review writeback with revision checks, reliable iPad layouts, robust support and onboarding | Advanced SSH/library gaps are disclosed |

Do not silently redefine a broad launch promise to match a small prototype. A terminal spike can be tiny; a paid professional tool must earn confidence.

## Defaults worth testing

- Opening a session observes it first; typing or choosing control makes the active terminal viewport explicit.
- A disconnected screen shows cached context and its age. It never displays cached “working” or “done” as fresh.
- Pending approvals remain visible until resolved or explicitly expired. Old completion notifications do not become an endless backlog.
- No automatic replay of uncertain shell input after reconnect.
- Plain SSH remains possible when richer awesoMux capabilities are absent. Unsupported features explain the missing requirement.
- Security, recovery access, accessibility, and export are not premium traps.

## Decisions for the next conversation

The most useful next choice is the first painful workflow to beat: phone check-ins or a two-hour iPad development session. The product can support both, but one should drive initial acceptance tests.

Other decisions can wait for evidence: mandatory Mac integration versus independent-host onboarding, terminal renderer, minimum OS/device set, pricing, source boundaries, and whether remote annotation editing belongs in the first paid beta. No implementation schedule is committed here.

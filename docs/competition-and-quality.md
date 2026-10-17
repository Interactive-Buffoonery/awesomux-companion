# Competition and the quality bar

Research snapshot: 2026-09-07. Primary product documentation and US App Store listings; no installed-app testing. “Documented” means the vendor describes the capability, not that this session verified reliability. Absence from the reviewed pages means unknown, not unsupported.

## The positioning problem

Moshi already competes directly for developers steering coding agents from mobile devices. Blink sets a substantial expectation for terminal input, SSH tooling, and iPad work. awesoMux needs enough of both to support its chosen workflow and a specific reason to switch.

## Moshi's documented offer

Moshi connects to user-controlled hosts, has a phone-oriented interface, and now describes a desktop companion as well. Mac/mobile presence alone is therefore insufficient differentiation. [Moshi product](https://getmoshi.app/), [documentation index](https://getmoshi.app/docs).

Its agent screen groups work by project and host, prioritizes pending decisions, and consolidates events per session. Usage tracking also exists. Do not position a multi-host agent dashboard as an empty market. [Agents and usage](https://getmoshi.app/docs/agents-usages).

Chat View reads supported agents' host transcripts through an SSH-forwarded gateway and sends responses into the running session. It is experimental, requires supported multiplexer/hook setup, and has agent-specific action limits. A structured view with a terminal fallback is already part of the competitive baseline. [Chat View](https://getmoshi.app/docs/chat-view).

Moshi also documents host-served diffs and SSH-forwarded development previews. These are useful workflows to match, not novelty claims. [Diff viewer](https://getmoshi.app/docs/diff-viewer), [browser preview](https://getmoshi.app/docs/browser-preview).

Its free tier includes SSH, two saved hosts, monitoring and push, with a small trial allowance for inbox actions. Pro adds Mosh, experimental ET, multiplexer pairing/reattach, unlimited inbox actions, richer attachments and customization. Subscription and lifetime purchases are both offered. [Subscription documentation](https://getmoshi.app/docs/subscription).

## Blink's documented offer

Blink describes Mosh and SSH, a configurable terminal, keyboard remapping, external-display use, local command-line tools, and device sync. Its site advertises a two-week trial followed by **$19.99/year**. This is a low price anchor for a professional terminal. [Blink product](https://blink.sh/).

SSH functionality includes tunneling, jump hosts and agents. Keys, certificates and authentication ergonomics are part of the product rather than setup left entirely to another device. [Advanced SSH](https://docs.blink.sh/advanced/advanced-ssh), [SSH keys](https://docs.blink.sh/basics/ssh-keys).

Blink documents Mosh for mobile network conditions, Files/SFTP integration, and a Code surface for web-based VS Code workflows. Its App Store listing also describes multiple windows/tabs and hardware-keyboard customization. [Mosh](https://docs.blink.sh/advanced/advanced-mosh), [Code](https://docs.blink.sh/advanced/code), [App Store](https://apps.apple.com/us/app/blink-shell-build-code/id1594898306).

The official pages reviewed do not establish a Moshi-style agent review/inbox feature set. That is a narrower finding than “Blink has no AI features.” Likewise, an older awesoMux note attributed native tmux control-mode UI to Blink; that was not established by these sources and should not inform implementation decisions.

## Comparative requirements

All awesoMux entries are proposed, not implemented.

| Capability | Competitive evidence | awesoMux requirement |
| --- | --- | --- |
| Robust terminal over mobile networks | Both emphasize Mosh/mobile continuity | Match the outcome with measured reconnect and input behavior; do not equate Tailscale with a transport recovery protocol |
| Serious keyboard and selection | Blink's central strength; Moshi documents terminal controls | Esc/Ctrl/Alt/Tab, shortcuts, IME, pointer and reliable selection are launch-quality work |
| Quick agent intervention | Moshi inbox and Chat View | Correct agent/session targeting, current context, supported decisions, immediate terminal fallback |
| Review while away | Moshi diff and preview | Read plans and changes in workspace context; validate whether anchored feedback improves the workflow |
| Sustained iPad development | Blink terminal, Files and Code | Terminal plus artifact side-by-side, reliable focus, remote editor, file handoff and preview |
| Desktop/mobile relationship | Moshi has desktop and mobile surfaces | Preserve awesoMux's actual workspace identity and artifacts; verify the experience is better |
| Terminal internals | Multiple products can use existing engines | Correctness and battery behavior matter; the engine name is not a moat |
| Host setup and credentials | Established connection/key tooling | A first connection a new user can complete without the founder on a call |
| Privacy | Competitors make privacy claims too | State actual data paths and defaults; content stays direct unless explicitly shared |

## Pricing evidence has limits

The Moshi US listing exposes several purchase records: monthly $6.99/$7.99, yearly $59.99/$69.99, and lifetime $249, alongside founder/pioneer entries. These are visible SKUs, not proof that a new customer is offered every option today. Checkout and regional pricing were not tested; the web pricing page could not be retrieved reliably. Use **roughly $60–70/year as an observed comparison range**, not a quoted current universal offer. [Moshi US listing](https://apps.apple.com/us/app/moshi-herdr-tmux-on-ssh-mosh/id6757859949).

Ignore stars/download guesses as market sizing. Listings and pricing show that commercial products exist; they do not reveal revenue, retention, or how many people want awesoMux.

## What “as good” needs to mean

Run the same jobs on the same host, hardware, OS, agent versions, network, font size and terminal workload. Record the competitor build and account tier. Below are **proposed acceptance targets**, not measured results or service guarantees.

| Area | Smallest useful comparison | Candidate gate |
| --- | --- | --- |
| Setup | Fresh host/key setup, then first useful command | At least 4 of 5 target testers complete it unaided in 10 minutes; record every manual intervention |
| Reconnect | 20 Wi-Fi/cellular transitions, 20 background/foreground cycles, 5 app terminations | Same durable host process; no wrong session, unexpected local shell, lost draft or duplicated command |
| Recovery speed | Usable network restored, app foregrounded, unlocked credentials | Target p95 under 3 seconds to an interactive existing session; include failures, not only successful attempts |
| Input correctness | Vim/Neovim, shell history, Ctrl-C/D/Z, Esc, Alt sequences, pasted multiline text, CJK composition, emoji | No lost/duplicated input; correct composition and bracketed paste; documented protocol gaps |
| Perceived latency | Stable network and controlled 150 ms latency/1% loss profile | Compare to both apps; measure input-to-paint distribution and ability to interrupt output, not just throughput |
| Scrollback | Long build log, search/select/copy, Unicode, reconnect during output | Bounded memory; exact selected text; explicit retained-history limits; no silent substitution of transcript for terminal history |
| Two clients | Mac plus phone, then Mac plus iPad; resize, type, disconnect controller | Observer cannot unexpectedly resize the Mac; control transfer visible; one input submission per action |
| Agent action | Resolve on Mac while phone card is open; retry after response loss; expire request | Stale card cannot authorize new work; repeated action does not execute twice; unsupported cases open terminal |
| Push | Locked phone, delayed/duplicate push, denied notification permission, stale destination | Correct target; reconnect refresh before action; app remains usable without pushes; measure delivery latency without promising APNs deadlines |
| Files/review | Upload image; inspect binary/large diff; edit plan while host changes it | Right host/path; bounded data; conflict shown; no silent file overwrite |
| iPad | Two-hour work session, resize window, attach/detach keyboard, external display | Predictable focus and shortcuts; no lost selection/draft or terminal corruption |
| Accessibility | VoiceOver journey, large Dynamic Type chrome, contrast, Reduce Motion | Connect, inspect status, select target and respond without color-only or gesture-only controls |
| Battery/performance | 30-minute idle and active runs under matched conditions | Compare energy, temperature and memory against both competitors; investigate regressions before adding visual effects |

Test on physical devices. A simulator can validate flows but cannot establish cellular roaming, keyboard hardware, battery, push delivery, or memory-pressure quality.

“As good as Blink” for the intended workflow is different from exhaustive feature parity. If testers rely on SSH certificates, agent forwarding, SOCKS, Files providers or specialized escape sequences, either support those before claiming replacement or clearly narrow the supported audience.

## Additional substitutes to watch

Claude Code's own Remote Control lets users continue an existing local session from another device. It is an especially relevant substitute for a Claude-only check-in app. Keep provider-independent terminals and workspace review useful even if agent vendors improve their own mobile access. [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control).

Happy, Termius, Prompt and Secure ShellFish merit a subsequent hands-on pass; they are not scored here. Also test the zero-new-product alternative: existing terminal + existing multiplexer + existing notifications. awesoMux must save enough setup or context-switching effort to justify becoming another daily tool.

## Evidence needed to claim differentiation

Recruit users already paying for Moshi or Blink and ask them to reproduce a recent real task. Observe where they switch apps, reconstruct context or abandon the phone/tablet. Then repeat with a prototype. Ask what they would keep paying for after the novelty wears off.

The first useful result is not “they liked the design.” It is “they completed the same task with fewer corrections, returned next week, and chose this for work they previously did elsewhere.”

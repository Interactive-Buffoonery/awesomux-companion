# Business potential and a career-pivot path

2026-09-07 · private founder discussion · hypotheses and arithmetic, not a revenue forecast or a decision to leave employment.

## The ambition deserves a commercial test

awesoMux could become a business, and the mobile product could give it a clearer paid offer. It could also become a strong portfolio for native developer-tool work before it supports a salary. Those are two useful outcomes; neither requires treating every feature idea as an obligation.

The most important constraint is sustainable effort. A product intended to create more autonomy should not turn into a second exhausting job with several services to keep alive. Start with customer-owned hosts, an existing terminal engine, a narrow supported workflow, and evidence from real use.

## What someone might pay for

Proposed offer: **a professional awesoMux workspace across Mac, iPhone and iPad, with reliable remote access and useful review tools.**

Candidate reasons to pay are saved setup time, easier review, fewer lost sessions, and being able to act away from the desk without reconstructing the whole task. These benefits must appear in user behavior, not just interview compliments.

The first audience is reachable through awesoMux's existing users and contributors. Its size, willingness to pay and mobile-device mix are unknown. Count them before using the desktop community as a market-size estimate.

A private native app is not clone-proof, an open app is not automatically unmonetizable, and push infrastructure is not inherently a moat. The durable advantage would be a well-maintained workflow, a recognizable product, trust, distribution, and repeated customer use.

## Product packaging to test

| Model | Benefits | Costs or limits |
| --- | --- | --- |
| Annual professional app license | Clear payment for ongoing native product work; predictable renewal experiment | Must keep earning renewals; entitlement/restore support |
| One-time app purchase, paid major upgrades | Attractive to subscription-averse developers; understandable ownership | Revenue arrives unevenly; ongoing services need separate funding |
| Useful free entry plus paid workspace features/services | Easier trial and potential desktop cross-promotion | Conversion may be low; free support and infrastructure still cost money |

Working recommendation: test an annual professional offer with a meaningful trial against a one-time-license alternative. Use **$39, $59 and $79/year** as research anchors, not launched prices. The [competition document](competition-and-quality.md#pricing-evidence-has-limits) records the observed price context; actual willingness to pay for awesoMux is unknown.

Do not charge solely for basic push delivery when a direct competitor includes it in a free tier. Charge for the overall workflow and maintenance. Do not promise lifetime hosted connectivity, unbounded transfer or included model inference before costs are measured.

Possible free entry: a useful single-host terminal or read-only workspace trial. Possible paid value: polished cross-device workspace/review, multiple host organization, and optional managed convenience. The exact boundary needs user testing and a check against any prior public commitments; the July plan's “free forever” language is not proof that such a promise was published or approved.

Security, accessibility, export and recovery should remain baseline behavior at every tier. Expiry must not kill host sessions or hold user files hostage.

## Revenue arithmetic, without fantasy market sizing

Illustration: yearly retail price minus an assumed 15% store commission. Apple offers a 15% rate to enrolled, eligible Small Business Program participants; eligibility and enrollment are not established for this project. Actual proceeds also depend on storefront, taxes, refunds, currency and applicable terms. [Apple Small Business Program](https://developer.apple.com/app-store/small-business-program/).

| Annual price | After assumed 15% fee per customer/year | Customers for $60k/year | Customers for $120k/year |
| --- | ---: | ---: | ---: |
| $39 | $33.15 | 1,810 | 3,620 |
| $59 | $50.15 | 1,197 | 2,393 |
| $79 | $67.15 | 894 | 1,788 |

These are **receipts after one assumed fee**, before operating costs, acquisition, support, refunds, founder compensation split, benefits, or personal tax. They are not take-home pay. Counts round up and assume full-price annual customers for the period. At $59/year with a 30% fee assumption, the $120k figure becomes 2,906 customers.

For a more useful decision model:

```text
annual contribution per customer
  = collected annual price after store fees/refunds
    - variable annual service/support cost

customers required
  = ceil((desired total founder compensation + fixed annual business costs)
         / annual contribution per customer)
```

At a hypothetical 80% annual renewal rate, a base of 2,393 customers loses roughly 479 renewals each year; that many replacements are needed merely to stay level. Neither that retention assumption nor a customer-acquisition rate is measured. Track contribution and renewals, not gross launch revenue alone.

The target is therefore a few thousand retained paying customers at these prices, not an implausible million-user requirement—but acquiring and supporting those customers is substantial work, and no evidence yet says this product will do it.

## Evidence gates instead of a speculative release date

The quantities below are suggested small experiments. They are not statistically representative market research and do not certify product-market fit.

| Gate | Work | Evidence to continue |
| --- | --- | --- |
| 1. Repeated problem | Observe/interview 10 developers, including current Moshi/Blink customers and people who tried mobile development and stopped | At least 5 show a recent recurring problem that workspace continuity plausibly solves; record counterexamples |
| 2. Coherent prototype | Demonstrate the signature workflow; include a real terminal/reconnect experiment before committing to a full build | Users understand what improves over their current tools; the terminal has no fundamental feasibility blocker |
| 3. Repeated use | Put a narrow TestFlight build in 5–10 external users' hands for several weeks | Meaningful repeat sessions after novelty; observe failure and recovery, not just opens |
| 4. Willingness to pay | Present a concrete supported feature set and actual price through an appropriate beta/launch purchase route | First 20 paying customers outside the immediate contributor circle, with reasons they chose it |
| 5. Sustainable growth | Measure retention, renewals where available, support load, variable cost and acquisition source | Enough repeatable contribution to support a realistic expansion of time invested |

Interview prompts: “Show me the last time you wanted to continue on your phone”; “Where did you get stuck?”; “What do you use and pay for now?”; “What would make you abandon this after a week?” Avoid “Wouldn't it be cool if…” questions.

A landing page and signup form are useful only when testing a concrete promise. Interviews and outreach are proposed here; no messages were sent to potential customers, no accounts were created, and no money was collected.

## Distribution that fits the product

Start with opt-in desktop users and developers already discussing remote terminal workflows. Show an honest recorded task: leave the Mac, review/respond on the phone, work on iPad, return to the same state. Publish technical evidence and limitations when appropriate.

Separate funnels for existing awesoMux users and new standalone mobile users. If only desktop enthusiasts adopt it, that is useful evidence about the market ceiling and onboarding dependency. Do not spend on acquisition until repeated use and conversion exist.

Track a small set of opt-in, content-free events or a manual research log: first successful connection, successful reconnect, completed remote intervention, second-week use, purchase, support request and cancellation reason. Never collect terminal transcripts to count activation. An explicit metrics/privacy design is needed before adding analytics.

## Career paths this work can support

| Path | Evidence to build | What it avoids depending on |
| --- | --- | --- |
| Full-time product business | Retained paid users, contribution margin, repeatable acquisition, manageable support | A successful launch spike masquerading as recurring income |
| Native developer-tools role | Shipped app, mobile lifecycle/network engineering, accessible input, measured quality, concise public case study | The business already replacing an entire salary |
| Consulting or contract bridge | Reusable expertise and a credible demonstrated product; clearly bounded paid engagements | Immediately funding all living costs from app subscriptions |

Before committing to a commercial offering, eD! and Sarah should explicitly agree who owns and maintains the mobile product, branding, publisher account, service obligations, and how revenue/expenses are shared. The existing MIT code license does not answer those collaboration questions. This session did not make those decisions or review employment/IP agreements.

Before any employment transition, replace the illustrative targets with actual household needs, benefits, tax provision, runway, business costs and ownership allocation. A concrete trigger would be an agreed period of repeatable net contribution plus adequate runway and a sustainable workload. The duration and threshold belong to eD!'s circumstances; they are deliberately not invented here.

## What would make us stop or change direction

- Most target users already solve the job comfortably with existing tools and cannot name a meaningful advantage.
- The product only feels useful when several hard new services and integrations all ship at once.
- Users praise it but do not return, switch real work to it, or pay.
- Support effort scales faster than receipts, especially with host networking and credential setup.
- iPad terminal quality requires an engine investment larger than the validated opportunity.
- Maintaining the product makes the founder's available time and energy worse without credible progress toward autonomy.

In those cases, preserve the useful technical work, narrow the scope, or use the shipped evidence for the portfolio/contract path. The work can still move a career forward without forcing an unsupported business thesis.

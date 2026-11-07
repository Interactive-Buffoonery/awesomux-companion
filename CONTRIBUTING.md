# Contributing

Keep each PR focused on one change. Size labels are informational; test changes
are counted separately when a PR also changes other files.

Use the [PR template](.github/pull_request_template.md) headings. Remove its
placeholder comments. Write PR text and merge risk updates in simple English or
ASD-STE100 (Simplified Technical English). List the models used after `Models:`
under Notes, or write `None`. For visible iOS changes, include before/after
screenshots or a short video from the running app under UI / UX.

Run the checks for the files you change:

- `node --test .github/scripts/test/*.test.mjs` checks the PR validator.
- `python3 -m unittest discover -s ios/script/tests -p 'test_*.py'` checks build
  tooling with synthetic files and mocked commands. It does not build or sign.
- `swift test` at the root tests the shared protocol package on macOS. It does
  not build or run the iOS app.
- For app changes, follow [the iOS guide](ios/README.md) for the source-built
  renderer, project generation, app tests, and device acceptance. Edit
  `ios/project.yml` rather than generated Xcode projects.

On Midnight Pro and Pinguchy, start builds and tests through `process-gate` from
a clean committed tree. Use T3 Code device tools for simulators. CI guards need
no signing credentials, secrets, or simulator; they do not prove the app works
on a phone. Do not upload a TestFlight build as part of PR checks.

After verification, coding agents should use the read-only
[merge-risk skill](.agents/skills/merge-risk/SKILL.md) and put its one-line result
under Notes. The skill is advisory. The description check requires `Models:` but
does not require a filled merge risk line. Docs-only changes may omit UI / UX.

The PR description and size workflows run trusted code from the default branch.
They first become active after this setup lands. Existing PRs need descriptions
that follow the template at their next edit or push.

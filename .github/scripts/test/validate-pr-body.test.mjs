import test from "node:test";
import assert from "node:assert/strict";
import { validatePullRequest } from "../validate-pr-body.mjs";

const fullBody = `## Why
Make review safer.

## What's Included
- Add a trusted workflow.

## UI / UX
Not applicable because there is no visible change.

## Notes
Models: n/a

Merge risk: <!-- low / medium / high / unknown, the main reason, and how to recover -->
`;

const rejectionCases = [
  ...["Why", "What's Included", "UI / UX", "Notes"].map((heading) => ({
    name: `missing ${heading}`,
    body: fullBody.split(/(?=^## )/m).filter((section) => !section.startsWith(`## ${heading}\n`)).join(""),
    error: heading,
  })),
  { name: "placeholder", body: fullBody.replace("Make review safer.", "<!-- explain why -->"), error: "placeholder" },
  { name: "template instruction", body: fullBody.replace("Make review safer.", "<!-- What changed, and why should this change exist? Lead with the reviewer-facing outcome. -->"), error: "placeholder" },
  { name: "footer filling a section", body: fullBody.replace(/## Notes[\s\S]*$/, "## Notes\n") + "<!-- codesmith:footer -->\nManaged footer content.\n<!-- codesmith:autofix:enabled -->\n<!-- /codesmith:footer -->", error: "Notes" },
  { name: "blank models", body: fullBody.replace("Models: n/a", "Models: <!-- e.g. Claude Opus 5.5, or \"None\" -->"), error: "Models" },
];

test("rejects missing headings and template placeholders", () => {
  assert.equal(validatePullRequest({ body: fullBody, files: ["Sources/App.swift"] }).valid, true);
  for (const entry of rejectionCases) {
    assert.notEqual(entry.body, fullBody, entry.name);
    const result = validatePullRequest({ body: entry.body, files: ["Sources/App.swift"] });
    assert.equal(result.valid, false, entry.name);
    assert(result.errors.some((error) => error.includes(entry.error)), entry.name);
  }
});

test("docs-only descriptions may omit UI / UX", () => {
  const body = fullBody.replace(/## UI \/ UX[\s\S]*?(?=## Notes)/, "");
  assert.equal(validatePullRequest({ body, files: ["CONTRIBUTING.md", "docs/guide.md"] }).valid, true);
  assert.equal(validatePullRequest({ body, files: [".github/workflows/cheap-guards.yml"] }).valid, false);
});

test("accepts None and emphasized model labels", () => {
  for (const models of ["Models: None", "**Models:** gpt-6.1-sol"]) {
    assert.equal(validatePullRequest({ body: fullBody.replace("Models: n/a", models) }).valid, true);
  }
});

test("the untouched template fails and a completed template passes", async () => {
  const { readFile } = await import("node:fs/promises");
  const template = await readFile(new URL("../../pull_request_template.md", import.meta.url), "utf8");
  assert.equal(validatePullRequest({ body: template }).valid, false);
  const body = template.replace(/<!--[\s\S]*?-->/g, "")
    .replace("## Why", "## Why\nMake reviews clearer.")
    .replace("## What's Included", "## What's Included\nAdd PR checks.")
    .replace(/\| Before[\s\S]*?(?=## Notes)/, "Not applicable.\n\n")
    .replace("Models: ", "Models: None");
  assert.equal(validatePullRequest({ body, files: [".github/workflows/pr-template.yml"] }).valid, true);
});

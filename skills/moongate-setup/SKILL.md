---
name: moongate-setup
description: Turn repository instructions (CLAUDE.md, AGENTS.md, CONTRIBUTING.md) into Moongate semantic rules in .moongate.json, then validate them locally. Use when the user runs `/moongate-setup`, asks to set up or install Moongate, asks to add or update Moongate rules, or asks which repository instructions can be enforced semantically in CI. Authoring only: it never calls the evaluation API, edits workflows, or reads secrets.
---

# Moongate Setup

Author advisory semantic rules. The CI runner evaluates rules; it never writes
them. Schema: `references/moongate.schema.json` (adjacent to this file).

**Scope.** Unless the user asks in this conversation, do NOT: enable
`blocking`, call the TypeSafe API, run `moongate check`, read secrets, edit
workflows or `action.yml`, install linters, or delete rules you did not add.

## 1. Read the instructions

Read root and relevant nested `CLAUDE.md`, `AGENTS.md`, `AGENT.md`, and
contributor guidance, honouring the repository's scoping convention (a nested
file governs its subtree). Not every sentence is a rule.

## 2. Inspect the real tree

Read the directory layout and existing lint/test/CI configuration before
choosing globs. Globs must match paths that exist. Never call a deterministic
rule "already covered" without seeing the tool that covers it.

## 3. Classify every instruction

- **Deterministic** (formatting, line length, import order): name the linter
  that covers it; do not encode it as a rule.
- **Observable semantic** (visible in the changed code): encode it.
- **Process-only** ("run the tests", "think first"): report as unenforceable —
  a Git diff cannot prove a command ran or a thought occurred.
- **Too ambiguous** ("write clean code"): report and ask for a sharper phrasing.

## 4. Write rules

Atomic, one requirement each. Required: stable snake_case `id`, accurate
`source` citation, scoped `globs`, actionable `message`, and all three
criteria — `violation`, `compliant`, `insufficient_evidence` — with no others.
`context` entries are exact file paths, never globs. New rules are `advisory`.

Leave `thresholds` at the defaults unless the user asks. Verdict numbers drift
run to run on identical evidence (probability sd ~0.015 in a 10-replay sample,
enough that a gate inside the band split one unchanged pull request 4 ways
violation and 6 ways review), so a threshold tuned to sit just under one
observed answer converts sampling noise into a verdict change.
Preserve existing ids, rules and severities; change a rule only when its
source requirement changed.

## 5. Validate and report

Write `.moongate.json`, then run `moongate validate --config .moongate.json`.
If the CLI is unavailable, say validation could not run — never claim success.
Summarise added and changed rules, and every omitted requirement with its
reason. For each new rule, show one clean, one violating and one
insufficient-evidence example in the reply for human review.

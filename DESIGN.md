# Moongate

> Semantic CI gatekeeper: MoonBit runner, TypeSafe Jev decisions.

---

## 1. Premise

Repository guidelines in `CLAUDE.md`, `AGENTS.md`, or `CONTRIBUTING.md` are passive prose:
- AI agents (Claude Code, Cursor, Copilot) drift and ignore them.
- Human contributors rarely memorise subtle architectural rules.
- Generative LLM review bots emit unstructured prose that cannot reliably gate CI.

**Moongate** turns those guidelines into structured, evaluated rules:
- **Runner**: MoonBit native binary, no generative model, no plugin runtime.
- **Decision engine**: **Jev** (TypeSafe System One) returning a fixed Choice label with a probability distribution and a confidence value.
- **Boundary**: rule *authoring* happens in an interactive assistant skill. CI only *evaluates* committed rules.

Findings are **advisory by default**. A rule blocks CI only when its author marks it `blocking` and states explicit thresholds.

---

## 2. Architecture

```
                    AHEAD-OF-TIME (AOT) SETUP
       CLAUDE.md / AGENTS.md + local repository context
                               |
                  skills/moongate-setup (assistant)
                   - triages deterministic vs semantic
                   - writes Choice rubrics and globs
                   - runs `moongate validate` (no API call)
                               |
                        .moongate.json  (committed)

                     RUNTIME EVALUATION (CI)
                  pull_request event (same-repo only)
                               |
                  moongate check --base <sha> --config-ref <base sha>
                   1. resolves base/head/merge-base commits
                   2. selects committed changes by glob
                   3. builds evidence from exact blob ids
                   4. POST /v1/systemone (batched questions)
                   5. applies thresholds -> annotations + exit code
                               |
                   GitHub Actions annotations / job status
```

---

## 3. Separation of concerns

### A. Setup skill (`skills/moongate-setup`)
- Interactive assistant session. Ordinary file tools only; no API key.
- Triages each instruction: deterministic (route to a linter), observable semantic (encode), process-only (unenforceable by diff), too ambiguous (ask).
- Writes the three Choice criteria, scopes globs against the real tree, keeps ids stable, and runs `moongate validate`.
- Never enables blocking, never calls the API, never edits workflows.

### B. Runner (`moongate`)
- No generative model and no credential other than `TYPESAFE_API_KEY`.
- Reads only committed objects: no working-tree content, no repository code execution, no Git hooks, external diff drivers, or textconv filters.
- Emits GitHub annotations, machine-readable JSON, or text, with exit codes 0 / 1 / 2.
- One source tree, two builds. `src/core`, `src/runner` and `src/cli` are target-neutral; `src/host` declares the services they need (process execution, HTTPS, filesystem, stdout, environment, exit) as a record of functions. `src/host/native` supplies them from `moonbitlang/async`; `src/host/js` supplies them from Node. Imports resolve per package, not per target, so each backend has to be its own package.
- The GitHub Action runs the `--target js` build committed at `dist/moongate.js` (`runs: node20`). Callers need no MoonBit toolchain and no build step; CI fails if the committed bundle differs from a fresh build. The native binary remains the local and non-Actions path.

---

## 4. CLI contract

```text
moongate validate [--config PATH] [--format text|json|github]
moongate check --base REF [--head REF] [--config PATH] [--config-ref REF] [--format text|json|github]
moongate --help | --version
```

Defaults: config `.moongate.json`, head `HEAD`, format `text`. `check` must run from the repository root. With `--config-ref`, policy is read from that commit's tree, never the working tree, so a pull request cannot weaken the rules judging it.

Exit codes: `0` advisory/pass/not-applicable, `1` blocking violation, `2` configuration or operational failure. Missing configuration is always `2`; there is no silent skip.

---

## 5. Rule contract (`.moongate.json`)

```json
{
  "version": 1,
  "model": "jev-1.13.0",
  "rules": [
    {
      "id": "no_direct_sql_in_handlers",
      "source": "CLAUDE.md:28",
      "severity": "blocking",
      "globs": ["src/routes/**/*.mbt"],
      "exclude": [],
      "context": ["src/db/repo.mbt"],
      "thresholds": { "min_probability": 0.90, "min_confidence": 0.80 },
      "question": {
        "type": "choice",
        "instructions": "Does the change execute raw SQL inside an HTTP route handler instead of using the repository layer?",
        "criteria": {
          "violation": "A route handler runs SQL or opens a database connection directly.",
          "compliant": "Data access is delegated to the repository layer, or no data access changed.",
          "insufficient_evidence": "The change does not show the data-access path."
        }
      },
      "message": "Direct database query in a route handler. Use the repository interface per CLAUDE.md:28."
    }
  ]
}
```

Only `choice` questions exist, with exactly those three criteria. Unknown fields, duplicate JSON keys, duplicate rule ids, malformed globs, and blocking rules without explicit thresholds are rejected by `validate`. Canonical schema: `skills/moongate-setup/references/moongate.schema.json`.

---

## 6. Decision gates

For each applicable rule, with $P$ the probability of the returned label and $C$ its confidence:

1. `violation` with $P \ge$ `min_probability` and $C \ge$ `min_confidence` → **violation** (exit 1 if `blocking`, otherwise advisory exit 0).
2. `compliant` clearing both thresholds → **compliant**.
3. Anything else, including every `insufficient_evidence` answer → **review** (exit 0, warning annotation).

Thresholds are routing knobs for one pinned model, not measured accuracy. An advisory exit 0 does not assert compliance. Confidence is derived from the probability distribution; it is not independent evidence of correctness.

Repeated evaluation of one unchanged rule and diff (10 requests, `jev-1.13.0`, 2026-09-20) held the label at `violation` 10/10 while probability moved 0.73-0.84 (sd 0.027) and confidence 0.60-0.76 (sd 0.039). The label is stable; the numbers the thresholds compare against are not. A threshold placed inside that spread converts run-to-run sampling noise into a verdict change on an unchanged pull request, and for a blocking rule that means a red build on a re-run. Thresholds must therefore sit several standard deviations clear of where a rule lands in practice; a rule that repeatedly lands near its gate is miscalibrated, not marginal.

Conclusion precedence: `incomplete` (exit 2) > `blocked` (1) > `advisory` (0) > `pass` (0) > `not_applicable` (0).

A rule the runner could not evaluate — unrepresentable evidence, or evidence over the request budget — is judged by its own `severity`, exactly like a rule that was evaluated. A `blocking` rule concludes `incomplete` (exit 2), because it must never pass unproven. An `advisory` rule reports an `error` result with a `detail` string and concludes `advisory` (exit 0): it never had the authority to stop a merge, and "could not look" cannot be graver than "looked and found a violation". Unevaluated is never `compliant` and never counts toward `pass`. Run-level failures — unreadable configuration, missing or ambiguous merge base, a dead transport, a missing credential — stay in the report's `errors` and are unconditionally exit 2.

---

## 7. Evidence discipline

- Changes come from `git diff --raw -z` between the single merge base and head; multiple or missing merge bases fail with exit 2.
- Patches are generated from the exact recorded blob object ids, so a path filter can never pull in excluded descendants after a file becomes a directory.
- Binary, invalid-UTF-8, symlink, submodule, oversized (>8 MiB) and non-regular selected files stop that rule from being evaluated instead of being silently dropped; the rule's severity decides whether the run fails. A rule can exclude them explicitly.
- Each rule's evidence is one indivisible unit: a cross-file rule is never split into independently passing fragments. A unit over the 65536-byte request budget leaves that rule unevaluated, reported by severity. The budget is measured, not guessed: `jev-1.13.0` accepted a 149053-byte body (32827 input tokens) and rejected 152935 bytes with `max_tokens_exceeded`, and no transport limit appears below 8 MiB. 65536 bytes assumes a pessimistic 2 bytes per token against that ceiling; it is a byte guard, not a token count.
- Only configured evidence leaves the machine: no repository archive, no PR description, no branch names.

---

## 8. Credentials and CI

- The only credential is `TYPESAFE_API_KEY`, read from the environment. No CLI flag, no config field, no alias, no provider fallback. It is stripped from every Git child environment.
- `TYPESAFE_BASE_URL` may point at an API-compatible origin; plain HTTP is accepted only on numeric loopback addresses. TLS verification is never disabled.
- Applicable rules without a credential fail with exit 2. No matching rules means `not_applicable` with exit 0 and no request.
- Fork pull requests and Dependabot are skipped by the workflow conditions, because `${{ secrets.* }}` is empty on forks. Skipped jobs are marked skipped by GitHub; they are never reported as passing evaluations. There is no `pull_request_target`, `workflow_run` bridge, or proxy gateway.
- Same-repository workflow authors are trusted with the secret. Checking out the base commit protects the invoked action, not the workflow file itself.

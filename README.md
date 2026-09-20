# Moongate

Evaluate committed repository changes against semantic rules in CI, using [TypeSafe](https://typesafe.ai) Jev.

Linters check syntax. Moongate checks the rules you wrote in prose — "don't log credentials", "new endpoints need an authorization check", "migrations must be reversible" — against the actual diff, and reports them as pull-request annotations.

It is not a generative code reviewer. There is no model writing rules, no chat, no agent. Rules are structured, hand-reviewed JSON in your repository; CI only classifies the diff against them.

## What a run looks like

```
::warning title=moongate: no_secret_logging::Possible credential logging. Log a request id instead. (source: AGENTS.md: never log credentials) [paths: src/handlers.py] [choice=violation p=1.000 confidence=1.000]
::notice title=moongate::conclusion advisory (exit 0)
```

## Quickstart

1. Get a TypeSafe API key and add it as the repository secret `TYPESAFE_API_KEY`.
2. Commit a `.moongate.json` (see below).
3. Add the workflow:

```yaml
name: Semantic
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read

jobs:
  evaluate:
    # Forks never receive the secret, and a fork job must not look like a pass.
    if: >-
      github.event.pull_request.head.repo.full_name == github.repository &&
      github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v5
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          fetch-depth: 0
          persist-credentials: false
      - uses: brickfrog/moongate@v0
        with:
          base: ${{ github.event.pull_request.base.sha }}
          head: ${{ github.event.pull_request.head.sha }}
          api-key: ${{ secrets.TYPESAFE_API_KEY }}
```

The checkout is of the **base** commit, and the action reads policy from that commit. A pull request cannot weaken the rules that judge it; rule changes take effect after merge.

No toolchain step is needed. The runner is compiled to JavaScript and committed under `dist/`, so the action is `runs: node24` and starts in well under a second.

## Configuration

`.moongate.json` at the repository root:

```json
{
  "version": 1,
  "model": "jev-1.13.0",
  "rules": [
    {
      "id": "no_secret_logging",
      "source": "AGENTS.md: never log credentials",
      "severity": "advisory",
      "globs": ["src/**/*.py"],
      "exclude": ["src/**/test_*.py"],
      "context": [],
      "thresholds": { "min_probability": 0.90, "min_confidence": 0.80 },
      "question": {
        "type": "choice",
        "instructions": "Does this change log a credential, token, or Authorization header value?",
        "criteria": {
          "violation": "The change logs a credential or an Authorization header value.",
          "compliant": "The change logs no credential material, or redacts it.",
          "insufficient_evidence": "The supplied changes do not establish either."
        }
      },
      "message": "Possible credential logging. Log a request id instead."
    }
  ]
}
```

Full schema: [`skills/moongate-setup/references/moongate.schema.json`](skills/moongate-setup/references/moongate.schema.json).

Writing good rules is the hard part, so it lives in a skill rather than in the runner: copy [`skills/moongate-setup`](skills/moongate-setup) into your agent's skills directory and ask it to set Moongate up. It reads your `AGENTS.md`/`CLAUDE.md`, classifies each instruction as deterministic, semantically observable, or process-only, and drafts advisory rules for the second kind only. It never enables blocking and never calls the API.

## Severity and exit codes

| | exit | job |
|---|---|---|
| `advisory` violation, or any review verdict | 0 | green, annotated |
| `blocking` violation | 1 | red |
| configuration or operational failure | 2 | red |

Everything is advisory unless you explicitly set `"severity": "blocking"` and supply thresholds. A rule the runner could not evaluate — unrepresentable evidence, or evidence over the request budget — is judged by that same severity: blocking fails the run, advisory reports an error result and exits 0. Unevaluated is never a pass.

## Inputs

| input | required | default | meaning |
|---|---|---|---|
| `base` | yes | — | Base commit. Policy is read from this commit. |
| `head` | yes | — | Head commit to evaluate. |
| `api-key` | yes | — | TypeSafe key. Reaches the runner through the environment only. |
| `config` | no | `.moongate.json` | Root-relative config path. |
| `repository` | no | `.` | Working directory of the repository under evaluation. |

## What leaves your machine

Only the evidence a rule selects: the patches of matching changed files, plus any exact `context` files that rule names. No repository archive, no PR title or description, no branch names, no telemetry.

- Patches are generated from the exact committed blob ids, never from the working tree, so excluded paths cannot be pulled in by a rename or a file-to-directory change.
- Git hooks, external diff drivers, and textconv are disabled; `.gitattributes` cannot hide a selected file's contents.
- The key is read only from `TYPESAFE_API_KEY`, never appears in argv or a file, and is stripped from every `git` child environment.
- Fork and Dependabot pull requests are skipped by the workflow condition above, because a fork never receives the secret. GitHub marks them skipped; Moongate never reports them as passing.

Same-repository workflow authors are trusted with the secret. Reading policy from the base commit protects the action invocation, not the workflow file itself.

## Honest limits

- A model verdict is not proof. An advisory exit 0 does not assert compliance, and thresholds are routing knobs for one pinned model, not measured accuracy for your repository.
- Confidence is derived from the answer's probability distribution. It is not independent evidence that the answer is right.
- **Verdicts are not reproducible.** Ten identical requests for one rule, same pinned model, same evidence: the label was `violation` 10/10, but probability ranged 0.73-0.84 (sd 0.027) and confidence 0.60-0.76 (sd 0.039). A threshold inside that band makes a rule flip verdict on a plain CI re-run with no code change. Set thresholds well clear of where a rule actually lands - a few standard deviations, not one - and treat a rule that keeps landing near its gate as miscalibrated rather than borderline.
- Repository content is untrusted input to a model. The instruction prefix that says so is a precaution, not a security boundary.
- Each rule's evidence is one indivisible unit, capped at 65536 serialized bytes. Measured against `jev-1.13.0`: 149053 bytes (32827 input tokens) accepted, 152935 bytes rejected with `max_tokens_exceeded`; the cap assumes a pessimistic 2 bytes per token. A rule whose diff exceeds it is reported unevaluated rather than silently truncated — narrow its globs.
- The model is pinned. Changing it is an explicit edit, and it invalidates your thresholds.

## Local use

```bash
moon build --target native --release
_build/native/release/build/cmd/moongate/moongate.exe validate --config .moongate.json
_build/native/release/build/cmd/moongate/moongate.exe check --base main --format text
```

`validate` needs no credential and makes no network call.

## Development

```bash
moon check --target native && moon check --target js
moon test --target native
moon build --target native --release && moon build --target js --release
cp _build/js/release/build/cmd/moongate-js/moongate-js.js dist/moongate.js
_build/native/release/build/cmd/itest/itest.exe \
  --bin "$PWD/_build/native/release/build/cmd/moongate/moongate.exe" \
  --action "$PWD/dist/index.js"
```

The integration suite builds real Git repositories and a loopback API fixture; it needs no credential. CI runs it against both the native binary and the committed JavaScript bundle, and fails if `dist/` is stale.

Design rationale and threat model: [`DESIGN.md`](DESIGN.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).

#!/usr/bin/env python3
"""Consumer-visible integration tests for the Moongate CLI.

Every scenario drives the real binary against a real temporary Git repository.
A loopback HTTP fixture stands in for the TypeSafe API so the suite needs no
credential and makes no external request. Assertions only look at exit codes
and process output: no internal call counts, no source-text checks.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DUMMY_KEY = "test-key-do-not-log"

FAILURES: list[str] = []
PASSED = 0


class Fixture:
    """Local stand-in for the evaluation API."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.responses: list[tuple[int, str, dict]] = []
        self.server: ThreadingHTTPServer | None = None

    def queue(self, body, status: int = 200, headers: dict | None = None) -> None:
        if not isinstance(body, str):
            body = json.dumps(body)
        self.responses.append((status, body, headers or {}))

    def start(self) -> str:
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args) -> None:
                pass

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                raw = self.rfile.read(length)
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except Exception:
                    parsed = {"_unparsed": raw.decode("utf-8", "replace")}
                fixture.requests.append(
                    {
                        "path": self.path,
                        "auth": self.headers.get("authorization", ""),
                        "body": parsed,
                    }
                )
                if fixture.responses:
                    status, body, extra = fixture.responses.pop(0)
                else:
                    status, body, extra = 500, '{"error":"no fixture queued"}', {}
                payload = body.encode("utf-8")
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                for key, value in extra.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(payload)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def stop(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()


def answer(choice: str, probs: dict, confidence: float) -> dict:
    return {
        "type": "choice",
        "choice": choice,
        "probabilities": probs,
        "confidence": confidence,
    }


def response(answers: dict, model: str = "jev-1.13.0") -> dict:
    return {"model": model, "answers": answers, "usage": {"input_tokens": 10}}


def decisive(choice: str) -> dict:
    other = 0.01
    probs = {
        "violation": other,
        "compliant": other,
        "insufficient_evidence": other,
    }
    probs[choice] = 0.98
    return answer(choice, probs, 0.95)


class Repo:
    def __init__(self, path: str) -> None:
        self.path = path

    def git(self, *args: str) -> str:
        env = dict(os.environ)
        env.update(
            {
                "GIT_AUTHOR_NAME": "Test",
                "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test",
                "GIT_COMMITTER_EMAIL": "test@example.com",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
            }
        )
        out = subprocess.run(
            ["git", *args],
            cwd=self.path,
            env=env,
            capture_output=True,
            text=True,
        )
        if out.returncode != 0:
            raise RuntimeError("git %s failed: %s" % (args, out.stderr))
        return out.stdout

    def write(self, rel: str, content: str) -> None:
        full = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(content)

    def write_bytes(self, rel: str, content: bytes) -> None:
        full = os.path.join(self.path, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as handle:
            handle.write(content)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()


def new_repo(stack: list[str]) -> Repo:
    path = tempfile.mkdtemp(prefix="moongate-it-")
    stack.append(path)
    repo = Repo(path)
    repo.git("init", "-q", "-b", "main")
    return repo


def rule(**overrides) -> dict:
    base = {
        "id": "no_secret_logging",
        "source": "AGENTS.md:1",
        "severity": "advisory",
        "globs": ["src/**/*.py"],
        "thresholds": {"min_probability": 0.90, "min_confidence": 0.80},
        "question": {
            "type": "choice",
            "instructions": "Does the change log credentials?",
            "criteria": {
                "violation": "Credentials are written to a log.",
                "compliant": "No credentials are logged.",
                "insufficient_evidence": "Not enough context.",
            },
        },
        "message": "Do not log credentials.",
    }
    base.update(overrides)
    return base


def config(rules: list[dict], **extra) -> str:
    doc = {"version": 1, "model": "jev-1.13.0", "rules": rules}
    doc.update(extra)
    return json.dumps(doc, indent=2) + "\n"


def run(binary: str, repo: Repo, args: list[str], base_url: str | None = None,
        key: str | None = DUMMY_KEY) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("TYPESAFE_API_KEY", None)
    env.pop("TYPESAFE_BASE_URL", None)
    if key is not None:
        env["TYPESAFE_API_KEY"] = key
    if base_url is not None:
        env["TYPESAFE_BASE_URL"] = base_url
    return subprocess.run(
        [binary, *args],
        cwd=repo.path,
        env=env,
        capture_output=True,
        text=True,
    )


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASSED
    if condition:
        PASSED += 1
    else:
        FAILURES.append("%s: %s" % (name, detail))


def expect_exit(name: str, proc: subprocess.CompletedProcess, code: int) -> None:
    check(
        name,
        proc.returncode == code,
        "expected exit %d, got %d\nstdout=%s\nstderr=%s"
        % (code, proc.returncode, proc.stdout[:2000], proc.stderr[:2000]),
    )


def report(proc: subprocess.CompletedProcess) -> dict:
    return json.loads(proc.stdout)


def status_of(doc: dict, rule_id: str) -> str:
    for result in doc["results"]:
        if result["id"] == rule_id:
            return result["status"]
    return "<missing>"


# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------


def test_config_rejections(binary: str, stack: list[str]) -> None:
    repo = new_repo(stack)
    repo.write("src/a.py", "print(1)\n")
    repo.write(".moongate.json", config([rule()]))
    repo.commit("init")

    cases = {
        "invalid severity": config([rule(severity="warn")]),
        "duplicate rule id": config([rule(), rule()]),
        "unknown field": config([rule(extra_field=1)]),
        "blocking without thresholds": config(
            [{k: v for k, v in rule(severity="blocking").items() if k != "thresholds"}]
        ),
        "bad glob": config([rule(globs=["src/[a-z].py"])]),
        "embedded doublestar": config([rule(globs=["src/a**/b.py"])]),
        "bad rule id": config([rule(id="Bad-Id")]),
        "low probability threshold": config(
            [rule(thresholds={"min_probability": 0.4, "min_confidence": 0.8})]
        ),
        "unknown criteria label": config(
            [
                rule(
                    question={
                        "type": "choice",
                        "instructions": "x",
                        "criteria": {
                            "violation": "a",
                            "compliant": "b",
                            "insufficient_evidence": "c",
                            "maybe": "d",
                        },
                    }
                )
            ]
        ),
        "bool question": config(
            [
                rule(
                    question={
                        "type": "bool",
                        "instructions": "x",
                        "criteria": {"true": "a", "false": "b"},
                    }
                )
            ]
        ),
    }
    for label, text in cases.items():
        repo.write("bad.json", text)
        proc = run(binary, repo, ["validate", "--config", "bad.json", "--format", "json"])
        expect_exit("validate rejects %s" % label, proc, 2)
        doc = json.loads(proc.stdout)
        check(
            "validate reports %s" % label,
            doc["valid"] is False and doc["rule_count"] is None and doc["errors"],
            json.dumps(doc),
        )

    # Duplicate JSON keys must not silently overwrite a policy field.
    dup = (
        '{"version":1,"rules":[{"id":"a","severity":"blocking",'
        '"thresholds":{"min_probability":0.9,"min_confidence":0.8},'
        '"severity":"advisory","globs":["src/**/*.py"],'
        '"question":{"type":"choice","instructions":"x","criteria":'
        '{"violation":"a","compliant":"b","insufficient_evidence":"c"}},'
        '"message":"m"}]}'
    )
    repo.write("dup.json", dup)
    proc = run(binary, repo, ["validate", "--config", "dup.json", "--format", "json"])
    expect_exit("validate rejects duplicate JSON key", proc, 2)

    # A missing configuration is always exit 2, never a silent skip.
    proc = run(binary, repo, ["validate", "--config", "nope.json"])
    expect_exit("validate rejects missing config", proc, 2)
    proc = run(binary, repo, ["check", "--base", "HEAD", "--config", "nope.json"])
    expect_exit("check rejects missing config", proc, 2)

    # A valid configuration reports its rule count.
    proc = run(binary, repo, ["validate", "--format", "json"])
    expect_exit("validate accepts good config", proc, 0)
    check("validate rule count", json.loads(proc.stdout)["rule_count"] == 1, proc.stdout)


def test_glob_and_selection(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    # Long enough that Git's similarity heuristic can detect a rename later.
    body_a = "".join("value_%d = %d\n" % (i, i) for i in range(40))
    repo.write("src/a.py", body_a)
    repo.write("src/pkg/b.py", "print('b')\n")
    repo.write("docs/c.md", "text\n")
    repo.write(".moongate.json", config([rule()]))
    base = repo.commit("base")

    repo.write("src/a.py", body_a + "extra = 1\n")
    repo.write("src/pkg/b.py", "print('b2')\n")
    repo.write("docs/c.md", "text2\n")
    repo.commit("head")

    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("glob check succeeds", proc, 0)
    doc = report(proc)
    paths = doc["results"][0]["paths"]
    check("direct and nested children selected", paths == ["src/a.py", "src/pkg/b.py"], str(paths))
    state = fixture.requests[-1]["body"]["state"]
    sent = sorted(c["new_path"] for c in state["changes"])
    check("excluded path never sent", sent == ["src/a.py", "src/pkg/b.py"], str(sent))

    # Renames stay in scope from either side.
    repo.git("mv", "src/a.py", "src/renamed.py")
    repo.write("src/renamed.py", body_a + "extra = 2\n")
    repo.commit("rename")
    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("rename check succeeds", proc, 0)
    changes = fixture.requests[-1]["body"]["state"]["changes"]
    renames = [c for c in changes if c["status"] == "R"]
    check("rename recorded with both paths", len(renames) == 1, str(changes))

    # Rename out of scope: old path selected, new path is not.
    repo.git("mv", "src/pkg/b.py", "docs/b.py")
    repo.commit("rename out")
    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("rename-out check succeeds", proc, 0)
    changes = fixture.requests[-1]["body"]["state"]["changes"]
    moved = [c for c in changes if c.get("old_path") == "src/pkg/b.py"]
    check("rename out of scope still evaluated", len(moved) == 1, str(changes))


def test_merge_base(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write("src/a.py", "one\n")
    repo.write(".moongate.json", config([rule()]))
    base = repo.commit("base")

    repo.git("checkout", "-q", "-b", "feature")
    repo.write("src/a.py", "one\ntwo\n")
    repo.commit("feature 1")
    repo.write("src/a.py", "one\ntwo\nthree\n")
    repo.commit("feature 2")

    repo.git("checkout", "-q", "main")
    repo.write("src/unrelated.py", "main-only\n")
    main_tip = repo.commit("main moves on")
    repo.git("checkout", "-q", "feature")

    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", main_tip, "--format", "json"], url)
    expect_exit("diverged branch check succeeds", proc, 0)
    doc = report(proc)
    check("merge base resolved", doc["merge_base"] == base, json.dumps(doc)[:400])
    changes = fixture.requests[-1]["body"]["state"]["changes"]
    sent = sorted(c["new_path"] for c in changes)
    check("base-only file not sent", sent == ["src/a.py"], str(sent))
    patch = changes[0]["patch"]
    check(
        "both feature commits present in patch",
        "+two" in patch and "+three" in patch,
        patch,
    )


def test_config_ref_policy(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write("src/a.py", "clean\n")
    repo.write(".moongate.json", config([rule(severity="blocking")]))
    base = repo.commit("base")

    repo.write("src/a.py", "leak\n")
    repo.write(".moongate.json", config([rule(severity="advisory")]))
    repo.commit("head weakens policy")

    fixture.queue(response({"no_secret_logging": decisive("violation")}))
    proc = run(
        binary,
        repo,
        ["check", "--base", base, "--config-ref", base, "--format", "json"],
        url,
    )
    expect_exit("base policy still blocks", proc, 1)
    doc = report(proc)
    check("blocking severity from base", doc["results"][0]["severity"] == "blocking", proc.stdout)

    # A dirty working-tree config cannot influence a commit-backed run.
    repo.write(".moongate.json", config([]))
    repo.write("src/a.py", "uncommitted\n")
    fixture.queue(response({"no_secret_logging": decisive("violation")}))
    proc = run(
        binary,
        repo,
        ["check", "--base", base, "--config-ref", base, "--format", "json"],
        url,
    )
    expect_exit("working tree cannot weaken config", proc, 1)
    state = fixture.requests[-1]["body"]["state"]
    check(
        "uncommitted content not sent",
        "uncommitted" not in json.dumps(state),
        json.dumps(state)[:400],
    )
    repo.git("checkout", "--", ".")


def test_hostile_paths(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(globs=["src/**"])]))
    repo.write("src/keep.py", "x\n")
    base = repo.commit("base")

    weird = "src/a b\tc\nd.py"
    repo.write("src/-hyphen.py", "x\n")
    repo.write_bytes(weird, b"x\n")
    repo.write("src/inject.py", "x\n")
    repo.commit("weird names")

    fixture.queue(response({"no_secret_logging": decisive("violation")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("weird filenames evaluate", proc, 0)
    sent = sorted(c["new_path"] for c in fixture.requests[-1]["body"]["state"]["changes"])
    check("filename with space/tab/newline preserved", weird in sent, str(sent))
    check("leading hyphen filename preserved", "src/-hyphen.py" in sent, str(sent))

    fixture.queue(response({"no_secret_logging": decisive("violation")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "github"], url)
    expect_exit("github format exits advisory", proc, 0)
    for line in proc.stdout.splitlines():
        check(
            "annotation lines are single workflow commands",
            line.startswith("::warning ") or line.startswith("::notice ") or line.startswith("::error "),
            line,
        )
    check(
        "no raw newline injection in annotations",
        "%0A" in proc.stdout or "\n::" in proc.stdout,
        proc.stdout,
    )


def test_attribute_and_driver_isolation(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    marker = os.path.join(repo.path, "marker.txt")
    repo.write(".moongate.json", config([rule()]))
    repo.write("src/a.py", "before\n")
    base = repo.commit("base")
    repo.write("src/a.py", "after\n")
    repo.commit("head")

    # Configure a hostile external diff driver and a textconv filter.
    repo.git("config", "diff.hostile.command", "sh -c 'touch %s'" % marker)
    repo.git("config", "diff.hostile.textconv", "sh -c 'touch %s; cat'" % marker)
    repo.write(".gitattributes", "*.py diff=hostile -diff\n")

    fixture.queue(response({"no_secret_logging": decisive("violation")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("hostile diff config does not break the run", proc, 0)
    check("external diff driver never ran", not os.path.exists(marker), marker)
    patch = fixture.requests[-1]["body"]["state"]["changes"][0]["patch"]
    check("-diff attribute cannot hide content", "+after" in patch, patch)


def test_file_to_directory(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(globs=["src/**/*.py"], exclude=["src/thing/**"])]))
    repo.write("src/thing.py", "old\n")
    base = repo.commit("base")

    os.remove(os.path.join(repo.path, "src/thing.py"))
    repo.write("src/thing/secret.py", "SECRET_MATERIAL\n")
    repo.commit("file becomes directory")

    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("file-to-directory check succeeds", proc, 0)
    body = json.dumps(fixture.requests[-1]["body"])
    check("excluded descendant never transmitted", "SECRET_MATERIAL" not in body, body[:400])
    changes = fixture.requests[-1]["body"]["state"]["changes"]
    check(
        "legitimate deletion still visible",
        any(c["status"] == "D" and c["old_path"] == "src/thing.py" for c in changes),
        str(changes),
    )


def test_unsupported_evidence(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(globs=["src/**"])]))
    repo.write("src/a.py", "x\n")
    base = repo.commit("base")
    repo.write_bytes("src/blob.py", b"\x00\x01binary\n")
    repo.commit("binary")
    before = len(fixture.requests)
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("binary evidence fails", proc, 2)
    check("binary evidence made no request", len(fixture.requests) == before, "request sent")

    repo2 = new_repo(stack)
    repo2.write(".moongate.json", config([rule(globs=["src/**"])]))
    repo2.write("src/a.py", "x\n")
    base2 = repo2.commit("base")
    repo2.write_bytes("src/bad.py", b"\xff\xfe not utf8\n")
    repo2.commit("invalid utf8")
    proc = run(binary, repo2, ["check", "--base", base2, "--format", "json"], url)
    expect_exit("invalid UTF-8 evidence fails", proc, 2)

    repo3 = new_repo(stack)
    repo3.write(".moongate.json", config([rule(context=["link.txt"])]))
    repo3.write("src/a.py", "x\n")
    repo3.write("real.txt", "hello\n")
    os.symlink("real.txt", os.path.join(repo3.path, "link.txt"))
    base3 = repo3.commit("base")
    repo3.write("src/a.py", "y\n")
    repo3.commit("head")
    proc = run(binary, repo3, ["check", "--base", base3, "--format", "json"], url)
    expect_exit("symlink context fails", proc, 2)

    repo4 = new_repo(stack)
    repo4.write(".moongate.json", config([rule(context=["missing.txt"])]))
    repo4.write("src/a.py", "x\n")
    base4 = repo4.commit("base")
    repo4.write("src/a.py", "y\n")
    repo4.commit("head")
    proc = run(binary, repo4, ["check", "--base", base4, "--format", "json"], url)
    expect_exit("missing context on both sides fails", proc, 2)

    repo5 = new_repo(stack)
    repo5.write(".moongate.json", config([rule(globs=["src/**"])]))
    repo5.write("src/a.py", "x\n")
    base5 = repo5.commit("base")
    repo5.write("src/big.py", "# padding line\n" * 4000)
    repo5.commit("oversized")
    proc = run(binary, repo5, ["check", "--base", base5, "--format", "json"], url)
    expect_exit("oversized evidence fails", proc, 2)
    doc = report(proc)
    check("oversized reports incomplete", doc["conclusion"] == "incomplete", proc.stdout)


def test_credentials(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(globs=["src/**/*.py"])]))
    repo.write("docs/a.md", "x\n")
    base = repo.commit("base")
    repo.write("docs/a.md", "y\n")
    repo.commit("docs only")

    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url, key=None)
    expect_exit("no matching rules needs no key", proc, 0)
    doc = report(proc)
    check("conclusion not applicable", doc["conclusion"] == "not_applicable", proc.stdout)

    repo.write("src/a.py", "x\n")
    repo.commit("now applicable")
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url, key=None)
    expect_exit("applicable rule without key fails", proc, 2)
    check("actionable key diagnostic", "TYPESAFE_API_KEY" in proc.stdout, proc.stdout)

    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url, key="   ")
    expect_exit("whitespace key is missing", proc, 2)


def test_policy_thresholds(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule()]))
    repo.write("src/a.py", "x\n")
    base = repo.commit("base")
    repo.write("src/a.py", "y\n")
    repo.commit("head")

    exact = answer(
        "violation",
        {"violation": 0.90, "compliant": 0.05, "insufficient_evidence": 0.05},
        0.80,
    )
    fixture.queue(response({"no_secret_logging": exact}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("advisory violation exits 0", proc, 0)
    doc = report(proc)
    check("advisory violation status", status_of(doc, "no_secret_logging") == "violation", proc.stdout)
    check("advisory conclusion", doc["conclusion"] == "advisory", proc.stdout)

    below = answer(
        "violation",
        {"violation": 0.89, "compliant": 0.06, "insufficient_evidence": 0.05},
        0.95,
    )
    fixture.queue(response({"no_secret_logging": below}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("below threshold exits 0", proc, 0)
    check(
        "below threshold becomes review",
        status_of(report(proc), "no_secret_logging") == "review",
        proc.stdout,
    )

    fixture.queue(response({"no_secret_logging": decisive("insufficient_evidence")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("insufficient evidence exits 0", proc, 0)
    check(
        "insufficient evidence becomes review",
        status_of(report(proc), "no_secret_logging") == "review",
        proc.stdout,
    )

    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("compliant exits 0", proc, 0)
    doc = report(proc)
    check("compliant status", status_of(doc, "no_secret_logging") == "compliant", proc.stdout)
    check("pass conclusion", doc["conclusion"] == "pass", proc.stdout)

    # Blocking severity at exactly the thresholds fails the build.
    repo.write(".moongate.json", config([rule(severity="blocking")]))
    repo.commit("blocking policy")
    fixture.queue(response({"no_secret_logging": exact}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("blocking violation exits 1", proc, 1)
    check("blocked conclusion", report(proc)["conclusion"] == "blocked", proc.stdout)


def test_transport_failures(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(severity="blocking")]))
    repo.write("src/a.py", "x\n")
    base = repo.commit("base")
    repo.write("src/a.py", "y\n")
    repo.commit("head")

    bad_cases = {
        "missing answer": response({}),
        "wrong id": response({"other_rule": decisive("compliant")}),
        "invalid label": response({"no_secret_logging": answer(
            "maybe", {"violation": 0.5, "compliant": 0.3, "insufficient_evidence": 0.2}, 0.9)}),
        "bad probability sum": response({"no_secret_logging": answer(
            "violation", {"violation": 0.9, "compliant": 0.9, "insufficient_evidence": 0.9}, 0.9)}),
        "non maximal choice": response({"no_secret_logging": answer(
            "compliant", {"violation": 0.8, "compliant": 0.1, "insufficient_evidence": 0.1}, 0.9)}),
        "extra probability label": response({"no_secret_logging": {
            "type": "choice",
            "choice": "compliant",
            "probabilities": {"violation": 0.1, "compliant": 0.8,
                              "insufficient_evidence": 0.05, "other": 0.05},
            "confidence": 0.9,
        }}),
        "missing usage": {"model": "jev-1.13.0",
                          "answers": {"no_secret_logging": decisive("compliant")}},
        "empty model": response({"no_secret_logging": decisive("compliant")}, model=""),
        "duplicate json key": '{"model":"jev-1.13.0","model":"other","answers":{},"usage":{}}',
        "truncated json": '{"model":"jev-1.13.0","answers":',
        "server text": "not json at all: SERVER_INTERNAL_DETAIL",
    }
    for label, body in bad_cases.items():
        fixture.queue(body)
        proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
        expect_exit("rejects %s" % label, proc, 2)
        doc = report(proc)
        check("%s yields incomplete" % label, doc["conclusion"] == "incomplete", proc.stdout)
        check(
            "%s never leaks the key" % label,
            DUMMY_KEY not in proc.stdout and DUMMY_KEY not in proc.stderr,
            "key leaked",
        )
        check(
            "%s never echoes raw server text" % label,
            "SERVER_INTERNAL_DETAIL" not in proc.stdout,
            proc.stdout,
        )

    fixture.queue({"error": "rate limited"}, status=429,
                  headers={"x-typesafe-request-id": "req-123"})
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("rejects 429", proc, 2)
    check("status reported", "429" in proc.stdout, proc.stdout)
    check("request id reported", "req-123" in proc.stdout, proc.stdout)

    fixture.queue("", status=302, headers={"location": "https://evil.example.com/"})
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("does not follow redirects", proc, 2)

    # Unreachable origin.
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"],
               "http://127.0.0.1:9")
    expect_exit("unreachable origin fails", proc, 2)

    # Non-loopback plain HTTP origin is refused outright.
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"],
               "http://example.com")
    expect_exit("plain http to remote host refused", proc, 2)


def test_batching(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    repo = new_repo(stack)
    rule_a = rule(id="rule_a")
    rule_b = rule(id="rule_b", message="Second rule.")
    repo.write(".moongate.json", config([rule_a, rule_b]))
    repo.write("src/a.py", "x\n")
    repo.write("src/b.py", "x\n")
    base = repo.commit("base")
    repo.write("src/a.py", "y\n")
    repo.write("src/b.py", "y\n")
    repo.commit("head")

    fixture.queue(response({
        "rule_a": decisive("violation"),
        "rule_b": decisive("compliant"),
    }))
    before = len(fixture.requests)
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("shared-evidence batch succeeds", proc, 0)
    doc = report(proc)
    check("batched in one request", len(fixture.requests) - before == 1, "request count")
    check("distinct verdicts kept",
          status_of(doc, "rule_a") == "violation" and status_of(doc, "rule_b") == "compliant",
          proc.stdout)
    state = fixture.requests[-1]["body"]["state"]
    sent = sorted(c["new_path"] for c in state["changes"])
    check("cross-file rule sees all evidence", sent == ["src/a.py", "src/b.py"], str(sent))
    check("authorization header sent",
          fixture.requests[-1]["auth"] == "Bearer " + DUMMY_KEY,
          fixture.requests[-1]["auth"])
    check("endpoint path", fixture.requests[-1]["path"] == "/v1/systemone",
          fixture.requests[-1]["path"])

    # Distinct evidence forces separate batches; a later failure makes the whole
    # report incomplete rather than a partial pass.
    rule_c = rule(id="rule_c", globs=["src/a.py"])
    rule_d = rule(id="rule_d", globs=["src/b.py"])
    repo.write(".moongate.json", config([rule_c, rule_d]))
    repo.commit("split rules")
    fixture.queue(response({"rule_c": decisive("compliant")}))
    fixture.queue("nonsense", status=500)
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("later batch failure is incomplete", proc, 2)
    doc = report(proc)
    check("failed batch is not a pass", doc["conclusion"] == "incomplete", proc.stdout)


def test_result_order_follows_config(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    """Results are reported in configuration order, not production order."""
    repo = new_repo(stack)
    ids = ["z_first", "a_skipped", "m_applicable", "b_skipped"]
    rules = [
        rule(id="z_first", globs=["src/**/*.py"]),
        rule(id="a_skipped", globs=["never/**/*.py"]),
        rule(id="m_applicable", globs=["src/**/*.py"]),
        rule(id="b_skipped", globs=["other/**/*.py"]),
    ]
    repo.write(".moongate.json", config(rules))
    repo.write("src/a.py", "x\n")
    base = repo.commit("base")
    repo.write("src/a.py", "y\n")
    repo.commit("head")

    fixture.queue(response({
        "z_first": decisive("compliant"),
        "m_applicable": decisive("violation"),
    }))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("mixed-applicability check succeeds", proc, 0)
    got = [result["id"] for result in report(proc)["results"]]
    check("results follow configuration order", got == ids, str(got))

    # Reversing the configuration reverses the report.
    rules.reverse()
    repo.write(".moongate.json", config(rules))
    repo.commit("reorder")
    fixture.queue(response({
        "z_first": decisive("compliant"),
        "m_applicable": decisive("violation"),
    }))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("reordered check succeeds", proc, 0)
    got = [result["id"] for result in report(proc)["results"]]
    check("reordered results follow configuration", got == list(reversed(ids)), str(got))


def test_context_paths_are_literal(binary: str, stack: list[str], fixture: Fixture, url: str) -> None:
    """A context entry is an exact filename, never a Git pathspec."""
    repo = new_repo(stack)
    repo.write(".moongate.json", config([rule(context=["docs/sp*c.md"])]))
    repo.write("src/a.py", "x\n")
    repo.write("docs/spec.md", "CONTEXT_MATERIAL\n")
    base = repo.commit("base")
    repo.write("src/a.py", "y\n")
    repo.commit("head")

    before = len(fixture.requests)
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("wildcard context path does not resolve", proc, 2)
    check("no request for unresolved context", len(fixture.requests) == before, "request sent")
    check(
        "glob context never silently reads another file",
        "CONTEXT_MATERIAL" not in proc.stdout,
        proc.stdout,
    )

    # The exact same file resolves when named exactly.
    repo.write(".moongate.json", config([rule(context=["docs/spec.md"])]))
    repo.commit("exact context")
    fixture.queue(response({"no_secret_logging": decisive("compliant")}))
    proc = run(binary, repo, ["check", "--base", base, "--format", "json"], url)
    expect_exit("exact context path resolves", proc, 0)
    sent = fixture.requests[-1]["body"]["state"]["context"]
    check("context content supplied", sent and "CONTEXT_MATERIAL" in sent[0]["after"], str(sent))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    args = parser.parse_args()
    binary = os.path.abspath(args.bin)
    if not os.path.exists(binary):
        print("binary not found: %s" % binary, file=sys.stderr)
        return 2

    fixture = Fixture()
    url = fixture.start()
    stack: list[str] = []
    try:
        test_config_rejections(binary, stack)
        test_glob_and_selection(binary, stack, fixture, url)
        test_merge_base(binary, stack, fixture, url)
        test_config_ref_policy(binary, stack, fixture, url)
        test_hostile_paths(binary, stack, fixture, url)
        test_attribute_and_driver_isolation(binary, stack, fixture, url)
        test_file_to_directory(binary, stack, fixture, url)
        test_unsupported_evidence(binary, stack, fixture, url)
        test_credentials(binary, stack, fixture, url)
        test_policy_thresholds(binary, stack, fixture, url)
        test_transport_failures(binary, stack, fixture, url)
        test_batching(binary, stack, fixture, url)
        test_result_order_follows_config(binary, stack, fixture, url)
        test_context_paths_are_literal(binary, stack, fixture, url)
    finally:
        fixture.stop()
        for path in stack:
            shutil.rmtree(path, ignore_errors=True)

    print("passed %d checks" % PASSED)
    for failure in FAILURES:
        print("FAIL %s" % failure)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())

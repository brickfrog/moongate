// Evidence selection scenarios: globs, merge base, base policy, hostile
// filenames, Git configuration isolation, and unsupported evidence.

///|
async fn test_glob_and_selection(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  // Long enough that Git's similarity heuristic can detect a rename later.
  let body = StringBuilder()
  for i in 0..<40 {
    body.write_string("value_\{i} = \{i}\n")
  }
  let body_a = body.to_string()
  repo.write("src/a.py", body_a)
  repo.write("src/pkg/b.py", "print('b')\n")
  repo.write("docs/c.md", "text\n")
  repo.write(".moongate.json", config([rule([])]))
  let base = repo.commit("base")
  repo.write("src/a.py", body_a + "extra = 1\n")
  repo.write("src/pkg/b.py", "print('b2')\n")
  repo.write("docs/c.md", "text2\n")
  repo.commit("head") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("glob check succeeds", proc, 0)
  let paths = []
  for path in array_of(field(array_of(field(report(proc), "results"))[0], "paths")) {
    paths.push(text_of(path))
  }
  check(
    "direct and nested children selected",
    paths == ["src/a.py", "src/pkg/b.py"],
    paths.join(", "),
  )
  let sent = sent_paths(field(fixture.last().body, "state"))
  check("excluded path never sent", sent == ["src/a.py", "src/pkg/b.py"], sent.join(", "))

  // Renames stay in scope from either side.
  repo.git(["mv", "src/a.py", "src/renamed.py"]) |> ignore
  repo.write("src/renamed.py", body_a + "extra = 2\n")
  repo.commit("rename") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let renamed = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("rename check succeeds", renamed, 0)
  let changes = array_of(field(field(fixture.last().body, "state"), "changes"))
  let mut rename_count = 0
  for change in changes {
    if text_of(field(change, "status")) == "R" {
      rename_count += 1
    }
  }
  check("rename recorded with both paths", rename_count == 1, describe(changes))

  // Rename out of scope: the old path is selected, the new path is not.
  repo.git(["mv", "src/pkg/b.py", "docs/b.py"]) |> ignore
  repo.commit("rename out") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let moved = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("rename-out check succeeds", moved, 0)
  let out_changes = array_of(field(field(fixture.last().body, "state"), "changes"))
  let mut moved_count = 0
  for change in out_changes {
    if text_of(field(change, "old_path")) == "src/pkg/b.py" {
      moved_count += 1
    }
  }
  check("rename out of scope still evaluated", moved_count == 1, describe(out_changes))
}

///|
async fn test_merge_base(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write("src/a.py", "one\n")
  repo.write(".moongate.json", config([rule([])]))
  let base = repo.commit("base")
  repo.git(["checkout", "-q", "-b", "feature"]) |> ignore
  repo.write("src/a.py", "one\ntwo\n")
  repo.commit("feature 1") |> ignore
  repo.write("src/a.py", "one\ntwo\nthree\n")
  repo.commit("feature 2") |> ignore
  repo.git(["checkout", "-q", "main"]) |> ignore
  repo.write("src/unrelated.py", "main-only\n")
  let main_tip = repo.commit("main moves on")
  repo.git(["checkout", "-q", "feature"]) |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", main_tip, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("diverged branch check succeeds", proc, 0)
  let doc = report(proc)
  check(
    "merge base resolved",
    text_of(field(doc, "merge_base")) == base,
    clip(proc.stdout),
  )
  let state = field(fixture.last().body, "state")
  let sent = sent_paths(state)
  check("base-only file not sent", sent == ["src/a.py"], sent.join(", "))
  let patch = text_of(field(array_of(field(state, "changes"))[0], "patch"))
  check(
    "both feature commits present in patch",
    patch.contains("+two") && patch.contains("+three"),
    patch,
  )
}

///|
async fn test_config_ref_policy(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write("src/a.py", "clean\n")
  repo.write(".moongate.json", config([
    rule([("severity", Json::string("blocking"))]),
  ]))
  let base = repo.commit("base")
  repo.write("src/a.py", "leak\n")
  repo.write(".moongate.json", config([rule([])]))
  repo.commit("head weakens policy") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--config-ref", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("base policy still blocks", proc, 1)
  check(
    "blocking severity from base",
    text_of(field(array_of(field(report(proc), "results"))[0], "severity")) ==
    "blocking",
    clip(proc.stdout),
  )

  // A dirty working tree cannot influence a commit-backed run.
  repo.write(".moongate.json", config([]))
  repo.write("src/a.py", "uncommitted\n")
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let dirty = run_cli(
    repo,
    ["check", "--base", base, "--config-ref", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("working tree cannot weaken config", dirty, 1)
  let state = field(fixture.last().body, "state").stringify()
  check("uncommitted content not sent", !state.contains("uncommitted"), clip(state))
  repo.git(["checkout", "--", "."]) |> ignore
}

///|
async fn test_hostile_paths(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([rule([("globs", strings(["src/**"]))])]))
  repo.write("src/keep.py", "x\n")
  let base = repo.commit("base")
  let weird = "src/a b\tc\nd.py"
  repo.write("src/-hyphen.py", "x\n")
  repo.write(weird, "x\n")
  repo.write("src/inject.py", "x\n")
  repo.commit("weird names") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("weird filenames evaluate", proc, 0)
  let sent = sent_paths(field(fixture.last().body, "state"))
  check("filename with space/tab/newline preserved", sent.contains(weird), sent.join(", "))
  check("leading hyphen filename preserved", sent.contains("src/-hyphen.py"), sent.join(", "))
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let annotated = run_cli(
    repo,
    ["check", "--base", base, "--format", "github"],
    base_url=Some(fixture.origin),
  )
  expect_exit("github format exits advisory", annotated, 0)
  for line in annotated.stdout.split("\n") {
    let line = line.to_owned()
    if line.is_empty() {
      continue
    }
    check(
      "annotation lines are single workflow commands",
      line.has_prefix("::warning ") ||
      line.has_prefix("::notice ") ||
      line.has_prefix("::error "),
      line,
    )
  }
  // The hostile filename must survive as escaped text on one line. The
  // Python suite accepted "%0A" or any second annotation line, which every
  // multi-finding run satisfies; only the escaped spelling proves anything.
  check(
    "control characters in a path are escaped, not emitted raw",
    annotated.stdout.contains("src/a b\\tc\\nd.py") &&
    !annotated.stdout.contains("\t"),
    clip(annotated.stdout),
  )
}

///|
/// A repository-configured diff driver or textconv filter must never run, and
/// a `-diff` attribute must not hide evidence.
async fn test_attribute_and_driver_isolation(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  let marker = "\{repo.path}/marker.txt"
  repo.write(".moongate.json", config([rule([])]))
  repo.write("src/a.py", "before\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "after\n")
  repo.commit("head") |> ignore
  repo.git(["config", "diff.hostile.command", "sh -c 'touch \{marker}'"])
  |> ignore
  repo.git(["config", "diff.hostile.textconv", "sh -c 'touch \{marker}; cat'"])
  |> ignore
  repo.write(".gitattributes", "*.py diff=hostile -diff\n")
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("hostile diff config does not break the run", proc, 0)
  check("external diff driver never ran", !(@fs.exists(marker)), marker)
  let patch = text_of(
    field(
      array_of(field(field(fixture.last().body, "state"), "changes"))[0],
      "patch",
    ),
  )
  check("-diff attribute cannot hide content", patch.contains("+after"), patch)
}

///|
/// Replacing a file with a directory must not leak excluded descendants.
async fn test_file_to_directory(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([
    rule([("exclude", strings(["src/thing/**"]))]),
  ]))
  repo.write("src/thing.py", "old\n")
  let base = repo.commit("base")
  repo.remove("src/thing.py")
  repo.write("src/thing/secret.py", "SECRET_MATERIAL\n")
  repo.commit("file becomes directory") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("file-to-directory check succeeds", proc, 0)
  let body = fixture.last().body.stringify()
  check(
    "excluded descendant never transmitted",
    !body.contains("SECRET_MATERIAL"),
    clip(body),
  )
  let changes = array_of(field(field(fixture.last().body, "state"), "changes"))
  let mut deletion = false
  for change in changes {
    if text_of(field(change, "status")) == "D" &&
      text_of(field(change, "old_path")) == "src/thing.py" {
      deletion = true
    }
  }
  check("legitimate deletion still visible", deletion, describe(changes))
}

///|
/// Builds a repository whose single rule cannot be evaluated, for each way
/// that can happen. `severity` is the rule's severity.
async fn unevaluable_repo(kind : String, severity : String) -> (Repo, String) raise {
  let repo = new_repo()
  let overrides = [("severity", Json::string(severity))]
  match kind {
    "symlink context" => overrides.push(("context", strings(["link.txt"])))
    "missing context" => overrides.push(("context", strings(["missing.txt"])))
    _ => overrides.push(("globs", strings(["src/**"])))
  }
  repo.write(".moongate.json", config([rule(overrides)]))
  repo.write("src/a.py", "x\n")
  if kind == "symlink context" {
    repo.write("real.txt", "hello\n")
    repo.symlink("real.txt", "link.txt")
  }
  let base = repo.commit("base")
  match kind {
    "binary" => repo.write_bytes("src/blob.py", b"\x00\x01binary\n")
    "invalid utf8" => repo.write_bytes("src/bad.py", b"\xff\xfe not utf8\n")
    "oversized" => {
      let padding = StringBuilder()
      // Comfortably past the 65536-byte request budget once patched.
      for _ in 0..<12000 {
        padding.write_string("# padding line\n")
      }
      repo.write("src/big.py", padding.to_string())
    }
    _ => repo.write("src/a.py", "y\n")
  }
  repo.commit("head") |> ignore
  (repo, base)
}

///|
/// Evidence the runner cannot represent is never a silent omission, and the
/// rule's own severity decides whether the run fails: a blocking rule must
/// not pass unproven, an advisory rule was never allowed to fail the build.
async fn test_unsupported_evidence(fixture : Fixture) -> Unit raise {
  let kinds = [
    "binary", "invalid utf8", "symlink context", "missing context", "oversized",
  ]
  for kind in kinds {
    let (repo, base) = unevaluable_repo(kind, "advisory")
    let before = fixture.requests.length()
    let proc = run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some(fixture.origin),
    )
    expect_exit("advisory \{kind} does not fail the build", proc, 0)
    let doc = report(proc)
    check(
      "advisory \{kind} concludes advisory",
      conclusion(doc) == "advisory",
      clip(proc.stdout),
    )
    check(
      "advisory \{kind} is reported as an error result",
      status_of(doc, "no_secret_logging") == "error",
      clip(proc.stdout),
    )
    check(
      "advisory \{kind} explains why the rule was skipped",
      text_of(field(array_of(field(doc, "results"))[0], "detail")).length() > 0,
      clip(proc.stdout),
    )
    check(
      "advisory \{kind} sends no request",
      fixture.requests.length() == before,
      "request sent",
    )
    // Never a pass: unevaluated is not compliant.
    check(
      "advisory \{kind} is not a pass",
      conclusion(doc) != "pass",
      clip(proc.stdout),
    )

    let (strict, strict_base) = unevaluable_repo(kind, "blocking")
    let blocked = run_cli(
      strict,
      ["check", "--base", strict_base, "--format", "json"],
      base_url=Some(fixture.origin),
    )
    expect_exit("blocking \{kind} fails the build", blocked, 2)
    check(
      "blocking \{kind} concludes incomplete",
      conclusion(report(blocked)) == "incomplete",
      clip(blocked.stdout),
    )
  }
}

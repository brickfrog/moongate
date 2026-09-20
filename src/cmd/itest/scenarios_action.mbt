// The GitHub Action entry point: `node dist/index.js` driven by INPUT_*.
//
// The bundle scenarios drive the CLI directly, which bypasses the shim that
// maps inputs, changes directory, and removes the credential from the
// environment. That mapping is what a caller actually executes.

///|
/// Path of `dist/index.js`, empty when the suite runs without `--action`.
let action_entry : Ref[String] = { val: "" }

///|
/// Runs the action entry point with an INPUT_* environment.
async fn run_action(
  inputs : Array[(String, String)],
  extra_env : Array[(String, String)],
  path_prefix~ : String = "",
  entry~ : String = "",
) -> Proc raise {
  let env = base_env()
  for input in inputs {
    env["INPUT_" + input.0] = input.1
  }
  for entry in extra_env {
    env[entry.0] = entry.1
  }
  if !path_prefix.is_empty() {
    env["PATH"] = path_prefix + ":" + env.get("PATH").unwrap_or("/usr/bin:/bin")
  }
  // A node action always starts in the workspace, never in the repository
  // under evaluation: the shim is what enters it.
  let script = if entry.is_empty() { action_entry.val } else { entry }
  run_process("node", [script], "/", env)
}

///|
/// A copy of the action whose runner writes a stray JSON object to stderr
/// before the real one runs. Node's own startup warnings vary by version; this
/// reproduces the same hazard deterministically.
async fn noisy_action() -> String raise {
  let dir = @fs.tmpdir(prefix="moongate-it-noise-")
  temp_dirs.push(dir)
  let real = action_entry.val
  let mut cut = -1
  for i, c in real {
    if c == '/' {
      cut = i
    }
  }
  let runner = real[:cut].to_owned() + "/moongate.js"
  // A copy, not a require: `require` would give the real module its own
  // __dirname and it would spawn the real runner, skipping the decoy.
  @fs.write_file("\{dir}/index.js", @fs.read_file(real))
  @fs.write_file(
    "\{dir}/moongate.js",
    "process.stderr.write('{\"decoy\":1}\\n');\nrequire(\{json_string(runner)});\n",
  )
  dir + "/index.js"
}

///|
fn json_string(value : String) -> String {
  Json::string(value).stringify()
}

///|
/// The shim maps inputs, enters the repository, and keeps the credential out
/// of every child process.
async fn test_action_entry_point(fixture : Fixture) -> Unit raise {
  if action_entry.val.is_empty() {
    return
  }
  let repo = new_repo()
  repo.write(".moongate.json", config([rule([])]))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  let head = repo.commit("head")

  // A PATH shim records the environment every `git` child receives.
  let bin = @fs.tmpdir(prefix="moongate-it-bin-")
  temp_dirs.push(bin)
  let dump = "\{bin}/child-env.txt"
  @fs.write_file(
    "\{bin}/git",
    "#!/bin/sh\nenv >> \{dump}\nexec /usr/bin/git \"$@\"\n",
  )
  @fs.chmod("\{bin}/git", 0o755)
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let proc = run_action(
    [
      ("BASE", base),
      ("HEAD", head),
      ("REPOSITORY", repo.path),
      ("CONFIG", ".moongate.json"),
      ("API-KEY", dummy_key),
    ],
    [("TYPESAFE_BASE_URL", fixture.origin)],
    path_prefix=bin,
  )
  expect_exit("action entry point evaluates", proc, 0)
  check(
    "action emits a workflow annotation",
    proc.stdout.contains("::warning ") && proc.stdout.contains("::notice "),
    clip(proc.stdout),
  )
  check(
    "action reached the repository named by its input",
    fixture.last().path == "/v1/systemone",
    fixture.last().path,
  )
  check(
    "action never prints the credential",
    !proc.stdout.contains(dummy_key) && !proc.stderr.contains(dummy_key),
    "key leaked to output",
  )

  // The credential must not survive into any child environment, under either
  // its own name or the INPUT_* spelling the runtime exports.
  let child_env = @utf8.decode((@fs.read_file(dump)).binary()[:]) catch {
    _ => ""
  }
  check("git child observed", !child_env.is_empty(), "no git child ran")
  check(
    "credential never reaches a git child",
    !child_env.contains(dummy_key),
    "credential present in child environment",
  )

  // A blocking rule must fail the job through this path. The severity has to
  // be in the base commit: the shim always evaluates against base policy.
  let strict = new_repo()
  strict.write(".moongate.json", config([
    rule([("severity", Json::string("blocking"))]),
  ]))
  strict.write("src/a.py", "x\n")
  let strict_base = strict.commit("base")
  strict.write("src/a.py", "y\n")
  let strict_head = strict.commit("head")
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  let blocked = run_action(
        [
      ("BASE", strict_base),
      ("HEAD", strict_head),
      ("REPOSITORY", strict.path),
      ("API-KEY", dummy_key),
    ],
    [("TYPESAFE_BASE_URL", fixture.origin)],
  )
  expect_exit("action exits 1 on a blocking violation", blocked, 1)

  // Missing inputs fail with a workflow error, not a stack trace.
  let incomplete = run_action(
    [("BASE", base), ("REPOSITORY", repo.path)],
    [("TYPESAFE_BASE_URL", fixture.origin)],
  )
  expect_exit("action rejects a missing head input", incomplete, 2)
  check(
    "missing input reports a workflow error",
    incomplete.stdout.contains("::error title=moongate::"),
    clip(incomplete.stdout),
  )
}

///|
/// A report larger than the pipe buffer must arrive whole: `process.exit`
/// discards queued writes when stdout is a pipe, which is how Actions
/// captures it.
async fn test_large_report_is_not_truncated(fixture : Fixture) -> Unit raise {
  if action_entry.val.is_empty() {
    return
  }
  let repo = new_repo()
  // Long pre-authored messages push the report past 64 KiB while the request
  // stays small: a message is local text and is never transmitted.
  let rules = []
  let answers = []
  let filler = StringBuilder()
  for _ in 0..<400 {
    filler.write_string("padding that makes each finding long. ")
  }
  let message = filler.to_string()
  for i in 0..<12 {
    let id = "rule_\{i}"
    rules.push(rule([("id", Json::string(id)), ("message", Json::string(message))]))
    answers.push((id, decisive("violation")))
  }
  repo.write(".moongate.json", config(rules))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  let head = repo.commit("head")
  fixture.queue_json(response(answers))
  let proc = run_action(
    [
      ("BASE", base),
      ("HEAD", head),
      ("REPOSITORY", repo.path),
      ("API-KEY", dummy_key),
    ],
    [("TYPESAFE_BASE_URL", fixture.origin)],
  )
  expect_exit("large advisory report exits 0", proc, 0)
  check(
    "report exceeds the pipe buffer",
    proc.stdout.length() > 65536,
    "\{proc.stdout.length()} bytes",
  )
  // The conclusion line is written last, so its presence proves nothing was
  // discarded at exit.
  check(
    "final line survives process exit",
    proc.stdout.contains("::notice title=moongate::conclusion advisory"),
    clip(proc.stdout),
  )
}

///|
/// With a token, the action publishes a check run built from the same
/// evaluation that produced the annotations.
async fn test_action_publishes_a_check_run(fixture : Fixture) -> Unit raise {
  if action_entry.val.is_empty() {
    return
  }
  let repo = new_repo()
  repo.write(".moongate.json", config([rule([])]))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  let head = repo.commit("head")
  // One evaluation response, then the check-run reply.
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  fixture.queue_json({ "id": Json::number(1) })
  let before = fixture.requests.length()
  let proc = run_action(
    [
      ("BASE", base),
      ("HEAD", head),
      ("REPOSITORY", repo.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
  )
  expect_exit("check run path keeps the advisory exit code", proc, 0)
  check(
    "annotations still reach the log",
    proc.stdout.contains("::warning ") && proc.stdout.contains("::notice "),
    clip(proc.stdout),
  )
  // Exactly one evaluation: publishing must not re-run a paid check.
  let mut evaluations = 0
  let mut published : Json? = None
  for i in before..<fixture.requests.length() {
    let recorded = fixture.requests[i]
    if recorded.path == "/v1/systemone" {
      evaluations = evaluations + 1
    }
    if recorded.path == "/repos/owner/repo/check-runs" {
      published = Some(recorded.body)
    }
  }
  check("exactly one evaluation", evaluations == 1, "evaluations=\{evaluations}")
  match published {
    None => check("check run was created", false, "no check-run request")
    Some(body) => {
      check(
        "check run names the head commit",
        text_of(field(body, "head_sha")) == head,
        clip(body.stringify()),
      )
      check(
        "an advisory violation does not fail the check run",
        text_of(field(body, "conclusion")) == "success",
        clip(body.stringify()),
      )
      let output = field(body, "output")
      let annotations = array_of(field(output, "annotations"))
      check(
        "check run carries one annotation per finding",
        annotations.length() == 1,
        clip(output.stringify()),
      )
      check(
        "annotation points at the offending file",
        text_of(field(annotations[0], "path")) == "src/a.py",
        clip(annotations[0].stringify()),
      )
      check(
        "annotation states the runner verdict",
        text_of(field(annotations[0], "message")).contains("[violation]"),
        clip(annotations[0].stringify()),
      )
      check(
        "annotation level matches an advisory severity",
        text_of(field(annotations[0], "annotation_level")) == "warning",
        clip(annotations[0].stringify()),
      )
      check(
        "summary reports the conclusion",
        text_of(field(output, "summary")).contains("advisory"),
        clip(output.stringify()),
      )
    }
  }
  check(
    "the github token never reaches the log",
    !proc.stdout.contains("ghs_dummy_token") &&
      !proc.stderr.contains("ghs_dummy_token"),
    "token leaked",
  )

  // A blocking violation must fail the check run, not merely the job.
  let strict = new_repo()
  strict.write(".moongate.json", config([
    rule([("severity", Json::string("blocking"))]),
  ]))
  strict.write("src/a.py", "x\n")
  let strict_base = strict.commit("base")
  strict.write("src/a.py", "y\n")
  let strict_head = strict.commit("head")
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  fixture.queue_json({ "id": Json::number(2) })
  let blocked = run_action(
    [
      ("BASE", strict_base),
      ("HEAD", strict_head),
      ("REPOSITORY", strict.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
  )
  expect_exit("blocking violation still exits 1", blocked, 1)
  let last = fixture.last()
  check(
    "blocking violation fails the check run",
    text_of(field(last.body, "conclusion")) == "failure",
    clip(last.body.stringify()),
  )

// A clean pull request must publish too, and the report shares stderr with
  // anything the host runtime writes there. A wrapper puts a stray JSON object
  // ahead of the frame: that is the exact hazard, without depending on which
  // runtime warnings a given Node version happens to print.
  let clean = new_repo()
  clean.write(".moongate.json", config([rule([])]))
  clean.write("src/a.py", "x\n")
  let clean_base = clean.commit("base")
  clean.write("src/a.py", "y\n")
  let clean_head = clean.commit("head")
  let noisy = noisy_action()
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  fixture.queue_json({ "id": Json::number(3) })
  let passing = run_action(
    [
      ("BASE", clean_base),
      ("HEAD", clean_head),
      ("REPOSITORY", clean.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
    entry=noisy,
  )
  expect_exit("a compliant pull request still exits 0", passing, 0)
  let clean_run = fixture.last()
  check(
    "stray output before the frame does not break the report",
    clean_run.path == "/repos/owner/repo/check-runs",
    clean_run.path + " " + clip(passing.stdout),
  )
  check(
    "a compliant run publishes a successful check run",
    text_of(field(clean_run.body, "conclusion")) == "success",
    clip(clean_run.body.stringify()),
  )
  check(
    "a compliant check run pins the evaluated head",
    text_of(field(clean_run.body, "head_sha")) == clean_head,
    clip(clean_run.body.stringify()),
  )
  check(
    "a compliant check run carries no annotations",
    array_of(field(field(clean_run.body, "output"), "annotations")).length() == 0,
    clip(clean_run.body.stringify()),
  )

  // Rule text is author-controlled and is echoed into the report, so a rule
  // that spells the closing marker must not truncate the document.
  let spoof = new_repo()
  spoof.write(
    ".moongate.json",
    config([
      rule([
        (
          "message",
          Json::string("ends here --- moongate report end --- and continues"),
        ),
      ]),
    ]),
  )
  spoof.write("src/a.py", "x\n")
  let spoof_base = spoof.commit("base")
  spoof.write("src/a.py", "y\n")
  let spoof_head = spoof.commit("head")
  fixture.queue_json(response([("no_secret_logging", decisive("violation"))]))
  fixture.queue_json({ "id": Json::number(5) })
  let spoofed = run_action(
    [
      ("BASE", spoof_base),
      ("HEAD", spoof_head),
      ("REPOSITORY", spoof.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
  )
  expect_exit("a marker inside rule text still exits 0", spoofed, 0)
  check(
    "a spoofed end marker does not truncate the report",
    fixture.last().path == "/repos/owner/repo/check-runs" &&
    text_of(field(fixture.last().body, "head_sha")) == spoof_head,
    clip(spoofed.stdout),
  )

    // A ref name is not an object id: the check run must pin what was evaluated.
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  fixture.queue_json({ "id": Json::number(4) })
  let by_ref = run_action(
    [
      ("BASE", clean_base),
      ("HEAD", "HEAD"),
      ("REPOSITORY", clean.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
  )
  expect_exit("a ref-named head still exits 0", by_ref, 0)
  check(
    "a ref-named head is published as a resolved object id",
    text_of(field(fixture.last().body, "head_sha")) == clean_head,
    clip(fixture.last().body.stringify()),
  )

  // A refused publication is an operational failure, never a silent success.
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  fixture.queue_json({ "message": Json::string("Bad credentials") }, status=500)
  let refused = run_action(
    [
      ("BASE", base),
      ("HEAD", head),
      ("REPOSITORY", repo.path),
      ("API-KEY", dummy_key),
      ("GITHUB-TOKEN", "ghs_dummy_token"),
    ],
    [
      ("TYPESAFE_BASE_URL", fixture.origin),
      ("GITHUB_API_URL", fixture.origin),
      ("GITHUB_REPOSITORY", "owner/repo"),
    ],
  )
  expect_exit("a refused check run fails the job", refused, 2)
  check(
    "refusal reports a workflow error",
    refused.stdout.contains("::error title=moongate::"),
    clip(refused.stdout),
  )
}

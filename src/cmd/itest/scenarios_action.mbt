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
  repo : Repo,
  inputs : Array[(String, String)],
  extra_env : Array[(String, String)],
  path_prefix~ : String = "",
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
  run_process("node", [action_entry.val], "/", env)
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
    repo,
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
    strict,
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
    repo,
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
    repo,
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

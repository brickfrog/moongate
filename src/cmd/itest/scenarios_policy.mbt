// Credential, threshold, transport, and batching scenarios.

///|
async fn test_credentials(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([rule([])]))
  repo.write("docs/a.md", "x\n")
  let base = repo.commit("base")
  repo.write("docs/a.md", "y\n")
  repo.commit("docs only") |> ignore
  let skipped = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
    key=None,
  )
  expect_exit("no matching rules needs no key", skipped, 0)
  check(
    "conclusion not applicable",
    conclusion(report(skipped)) == "not_applicable",
    clip(skipped.stdout),
  )
  repo.write("src/a.py", "x\n")
  repo.commit("now applicable") |> ignore
  let missing = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
    key=None,
  )
  expect_exit("applicable rule without key fails", missing, 2)
  check(
    "actionable key diagnostic",
    missing.stdout.contains("TYPESAFE_API_KEY"),
    clip(missing.stdout),
  )
  expect_exit(
    "whitespace key is missing",
    run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some(fixture.origin),
      key=Some("   "),
    ),
    2,
  )
}

///|
async fn test_policy_thresholds(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([rule([])]))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  repo.commit("head") |> ignore
  let exact = answer(
    "violation",
    [("violation", 0.9), ("compliant", 0.05), ("insufficient_evidence", 0.05)],
    0.8,
  )
  fixture.queue_json(response([("no_secret_logging", exact)]))
  let at_threshold = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("advisory violation exits 0", at_threshold, 0)
  let doc = report(at_threshold)
  check(
    "advisory violation status",
    status_of(doc, "no_secret_logging") == "violation",
    clip(at_threshold.stdout),
  )
  check(
    "advisory conclusion",
    conclusion(doc) == "advisory",
    clip(at_threshold.stdout),
  )
  fixture.queue_json(
    response([
      (
        "no_secret_logging",
        answer(
          "violation",
          [
            ("violation", 0.89),
            ("compliant", 0.06),
            ("insufficient_evidence", 0.05),
          ],
          0.95,
        ),
      ),
    ]),
  )
  let below = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("below threshold exits 0", below, 0)
  check(
    "below threshold becomes review",
    status_of(report(below), "no_secret_logging") == "review",
    clip(below.stdout),
  )
  fixture.queue_json(
    response([("no_secret_logging", decisive("insufficient_evidence"))]),
  )
  let unclear = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("insufficient evidence exits 0", unclear, 0)
  check(
    "insufficient evidence becomes review",
    status_of(report(unclear), "no_secret_logging") == "review",
    clip(unclear.stdout),
  )
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let clean = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("compliant exits 0", clean, 0)
  check(
    "compliant status",
    status_of(report(clean), "no_secret_logging") == "compliant",
    clip(clean.stdout),
  )
  check("pass conclusion", conclusion(report(clean)) == "pass", clip(clean.stdout))

  // Blocking severity at exactly the thresholds fails the build.
  repo.write(".moongate.json", config([
    rule([("severity", Json::string("blocking"))]),
  ]))
  repo.commit("blocking policy") |> ignore
  fixture.queue_json(response([("no_secret_logging", exact)]))
  let blocked = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("blocking violation exits 1", blocked, 1)
  check(
    "blocked conclusion",
    conclusion(report(blocked)) == "blocked",
    clip(blocked.stdout),
  )
}

///|
/// No malformed response, error status, or unreachable origin may pass.
async fn test_transport_failures(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([
    rule([("severity", Json::string("blocking"))]),
  ]))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  repo.commit("head") |> ignore
  let bad_cases : Array[(String, String)] = [
    ("missing answer", response([]).stringify()),
    ("wrong id", response([("other_rule", decisive("compliant"))]).stringify()),
    (
      "invalid label",
      response([
        (
          "no_secret_logging",
          answer(
            "maybe",
            [
              ("violation", 0.5),
              ("compliant", 0.3),
              ("insufficient_evidence", 0.2),
            ],
            0.9,
          ),
        ),
      ]).stringify(),
    ),
    (
      "bad probability sum",
      response([
        (
          "no_secret_logging",
          answer(
            "violation",
            [
              ("violation", 0.9),
              ("compliant", 0.9),
              ("insufficient_evidence", 0.9),
            ],
            0.9,
          ),
        ),
      ]).stringify(),
    ),
    (
      "non maximal choice",
      response([
        (
          "no_secret_logging",
          answer(
            "compliant",
            [
              ("violation", 0.8),
              ("compliant", 0.1),
              ("insufficient_evidence", 0.1),
            ],
            0.9,
          ),
        ),
      ]).stringify(),
    ),
    (
      "extra probability label",
      response([
        (
          "no_secret_logging",
          answer(
            "compliant",
            [
              ("violation", 0.1),
              ("compliant", 0.8),
              ("insufficient_evidence", 0.05),
              ("other", 0.05),
            ],
            0.9,
          ),
        ),
      ]).stringify(),
    ),
    (
      "missing usage",
      Json::object(
        Map([
          ("model", Json::string("jev-1.13.0")),
          (
            "answers",
            Json::object(Map([("no_secret_logging", decisive("compliant"))])),
          ),
        ]),
      ).stringify(),
    ),
    (
      "empty model",
      response([("no_secret_logging", decisive("compliant"))], model="").stringify(),
    ),
    (
      "duplicate json key",
      "{\"model\":\"jev-1.13.0\",\"model\":\"other\",\"answers\":{},\"usage\":{}}",
    ),
    ("truncated json", "{\"model\":\"jev-1.13.0\",\"answers\":"),
    ("server text", "not json at all: SERVER_INTERNAL_DETAIL"),
  ]
  for entry in bad_cases {
    fixture.queue(entry.1)
    let proc = run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some(fixture.origin),
    )
    expect_exit("rejects \{entry.0}", proc, 2)
    check(
      "\{entry.0} yields incomplete",
      conclusion(report(proc)) == "incomplete",
      clip(proc.stdout),
    )
    check(
      "\{entry.0} never leaks the key",
      !proc.stdout.contains(dummy_key) && !proc.stderr.contains(dummy_key),
      "key leaked",
    )
    check(
      "\{entry.0} never echoes raw server text",
      !proc.stdout.contains("SERVER_INTERNAL_DETAIL"),
      clip(proc.stdout),
    )
  }
  fixture.queue(
    "{\"error\":\"rate limited\"}",
    status=429,
    headers=[("x-typesafe-request-id", "req-123")],
  )
  let limited = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("rejects 429", limited, 2)
  check("status reported", limited.stdout.contains("429"), clip(limited.stdout))
  check(
    "request id reported",
    limited.stdout.contains("req-123"),
    clip(limited.stdout),
  )
  fixture.queue("", status=302, headers=[
    ("location", "https://evil.example.com/"),
  ])
  expect_exit(
    "does not follow redirects",
    run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some(fixture.origin),
    ),
    2,
  )
  expect_exit(
    "unreachable origin fails",
    run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some("http://127.0.0.1:9"),
    ),
    2,
  )
  expect_exit(
    "plain http to remote host refused",
    run_cli(
      repo,
      ["check", "--base", base, "--format", "json"],
      base_url=Some("http://example.com"),
    ),
    2,
  )
}

///|
/// Rules sharing evidence travel in one request and keep distinct verdicts.
async fn test_batching(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([
    rule([("id", Json::string("rule_a"))]),
    rule([
      ("id", Json::string("rule_b")),
      ("message", Json::string("Second rule.")),
    ]),
  ]))
  repo.write("src/a.py", "x\n")
  repo.write("src/b.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  repo.write("src/b.py", "y\n")
  repo.commit("head") |> ignore
  fixture.queue_json(
    response([
      ("rule_a", decisive("violation")),
      ("rule_b", decisive("compliant")),
    ]),
  )
  let before = fixture.requests.length()
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("shared-evidence batch succeeds", proc, 0)
  let doc = report(proc)
  check(
    "batched in one request",
    fixture.requests.length() - before == 1,
    "\{fixture.requests.length() - before} requests",
  )
  check(
    "distinct verdicts kept",
    status_of(doc, "rule_a") == "violation" &&
    status_of(doc, "rule_b") == "compliant",
    clip(proc.stdout),
  )
  let sent = sent_paths(field(fixture.last().body, "state"))
  check("cross-file rule sees all evidence", sent == ["src/a.py", "src/b.py"], sent.join(", "))
  check(
    "authorization header sent",
    fixture.last().auth == "Bearer " + dummy_key,
    "unexpected authorization header",
  )
  check("endpoint path", fixture.last().path == "/v1/systemone", fixture.last().path)

  // Distinct evidence forces separate batches; a later failure makes the whole
  // report incomplete rather than a partial pass.
  repo.write(".moongate.json", config([
    rule([("id", Json::string("rule_c")), ("globs", strings(["src/a.py"]))]),
    rule([("id", Json::string("rule_d")), ("globs", strings(["src/b.py"]))]),
  ]))
  repo.commit("split rules") |> ignore
  fixture.queue_json(response([("rule_c", decisive("compliant"))]))
  fixture.queue("nonsense", status=500)
  let split = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("later batch failure is incomplete", split, 2)
  check(
    "failed batch is not a pass",
    conclusion(report(split)) == "incomplete",
    clip(split.stdout),
  )
}

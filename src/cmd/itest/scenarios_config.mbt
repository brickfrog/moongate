// Configuration validation, report ordering, and context-path scenarios.

///|
/// Every rejected configuration must fail before any network use.
async fn test_config_rejections() -> Unit raise {
  let repo = new_repo()
  repo.write("src/a.py", "print(1)\n")
  repo.write(".moongate.json", config([rule([])]))
  repo.commit("init") |> ignore
  let cases : Array[(String, String)] = [
    ("invalid severity", config([rule([("severity", Json::string("warn"))])])),
    ("duplicate rule id", config([rule([]), rule([])])),
    ("unknown field", config([rule([("extra_field", Json::number(1))])])),
    (
      "blocking without thresholds",
      config([
        rule([
          ("severity", Json::string("blocking")),
          ("thresholds", Json::null()),
        ]),
      ]),
    ),
    ("bad glob", config([rule([("globs", strings(["src/[a-z].py"]))])])),
    ("embedded doublestar", config([rule([("globs", strings(["src/a**/b.py"]))])])),
    ("bad rule id", config([rule([("id", Json::string("Bad-Id"))])])),
    (
      "low probability threshold",
      config([rule([("thresholds", thresholds(0.4, 0.8))])]),
    ),
    (
      "unknown criteria label",
      config([
        rule([
          (
            "question",
            Json::object(
              Map([
                ("type", Json::string("choice")),
                ("instructions", Json::string("x")),
                (
                  "criteria",
                  Json::object(
                    Map([
                      ("violation", Json::string("a")),
                      ("compliant", Json::string("b")),
                      ("insufficient_evidence", Json::string("c")),
                      ("maybe", Json::string("d")),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ]),
    ),
    (
      "bool question",
      config([
        rule([
          (
            "question",
            Json::object(
              Map([
                ("type", Json::string("bool")),
                ("instructions", Json::string("x")),
                (
                  "criteria",
                  Json::object(
                    Map([
                      ("true", Json::string("a")),
                      ("false", Json::string("b")),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ]),
    ),
  ]
  for entry in cases {
    repo.write("bad.json", entry.1)
    let proc = run_cli(repo, [
      "validate", "--config", "bad.json", "--format", "json",
    ])
    expect_exit("validate rejects \{entry.0}", proc, 2)
    let doc = report(proc)
    check(
      "validate reports \{entry.0}",
      field(doc, "valid") is False &&
      field(doc, "rule_count") is Null &&
      array_of(field(doc, "errors")).length() > 0,
      proc.stdout,
    )
  }

  // A duplicate JSON key must not silently overwrite a policy field.
  let dup =
    #|{"version":1,"rules":[{"id":"a","severity":"blocking",
    #|"thresholds":{"min_probability":0.9,"min_confidence":0.8},
    #|"severity":"advisory","globs":["src/**/*.py"],
    #|"question":{"type":"choice","instructions":"x","criteria":
    #|{"violation":"a","compliant":"b","insufficient_evidence":"c"}},
    #|"message":"m"}]}
  repo.write("dup.json", dup)
  expect_exit(
    "validate rejects duplicate JSON key",
    run_cli(repo, ["validate", "--config", "dup.json", "--format", "json"]),
    2,
  )

  // A missing configuration is always exit 2, never a silent skip.
  expect_exit(
    "validate rejects missing config",
    run_cli(repo, ["validate", "--config", "nope.json"]),
    2,
  )
  expect_exit(
    "check rejects missing config",
    run_cli(repo, ["check", "--base", "HEAD", "--config", "nope.json"]),
    2,
  )

  // A valid configuration reports its rule count.
  let good = run_cli(repo, ["validate", "--format", "json"])
  expect_exit("validate accepts good config", good, 0)
  check(
    "validate rule count",
    field(report(good), "rule_count") == Json::number(1),
    good.stdout,
  )
}

///|
/// Results are reported in configuration order, not production order.
async fn test_result_order_follows_config(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  let ids = ["z_first", "a_skipped", "m_applicable", "b_skipped"]
  let rules = [
    rule([("id", Json::string("z_first"))]),
    rule([
      ("id", Json::string("a_skipped")),
      ("globs", strings(["never/**/*.py"])),
    ]),
    rule([("id", Json::string("m_applicable"))]),
    rule([
      ("id", Json::string("b_skipped")),
      ("globs", strings(["other/**/*.py"])),
    ]),
  ]
  repo.write(".moongate.json", config(rules))
  repo.write("src/a.py", "x\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  repo.commit("head") |> ignore
  let answers = [
    ("z_first", decisive("compliant")),
    ("m_applicable", decisive("violation")),
  ]
  fixture.queue_json(response(answers))
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("mixed-applicability check succeeds", proc, 0)
  let got = result_ids(report(proc))
  check("results follow configuration order", got == ids, got.join(", "))

  // Reversing the configuration reverses the report.
  rules.rev_in_place()
  repo.write(".moongate.json", config(rules))
  repo.commit("reorder") |> ignore
  fixture.queue_json(response(answers))
  let again = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("reordered check succeeds", again, 0)
  let reversed = ids.copy()
  reversed.rev_in_place()
  let got_again = result_ids(report(again))
  check(
    "reordered results follow configuration",
    got_again == reversed,
    got_again.join(", "),
  )
}

///|
fn result_ids(doc : Json) -> Array[String] {
  let ids = []
  for result in array_of(field(doc, "results")) {
    ids.push(text_of(field(result, "id")))
  }
  ids
}

///|
/// A context entry is an exact filename, never a Git pathspec.
async fn test_context_paths_are_literal(fixture : Fixture) -> Unit raise {
  let repo = new_repo()
  repo.write(".moongate.json", config([
    rule([("context", strings(["docs/sp*c.md"]))]),
  ]))
  repo.write("src/a.py", "x\n")
  repo.write("docs/spec.md", "CONTEXT_MATERIAL\n")
  let base = repo.commit("base")
  repo.write("src/a.py", "y\n")
  repo.commit("head") |> ignore
  let before = fixture.requests.length()
  let proc = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("wildcard context path does not resolve", proc, 2)
  check(
    "no request for unresolved context",
    fixture.requests.length() == before,
    "request sent",
  )
  check(
    "glob context never silently reads another file",
    !proc.stdout.contains("CONTEXT_MATERIAL"),
    clip(proc.stdout),
  )

  // The same file resolves when named exactly.
  repo.write(".moongate.json", config([
    rule([("context", strings(["docs/spec.md"]))]),
  ]))
  repo.commit("exact context") |> ignore
  fixture.queue_json(response([("no_secret_logging", decisive("compliant"))]))
  let exact = run_cli(
    repo,
    ["check", "--base", base, "--format", "json"],
    base_url=Some(fixture.origin),
  )
  expect_exit("exact context path resolves", exact, 0)
  let context = array_of(field(field(fixture.last().body, "state"), "context"))
  check(
    "context content supplied",
    context.length() == 1 &&
    text_of(field(context[0], "after")).contains("CONTEXT_MATERIAL"),
    describe(context),
  )
}

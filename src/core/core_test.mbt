///|
fn sample_rule(severity : Severity, thresholds : Thresholds) -> Rule {
  {
    id: "r",
    source: None,
    severity,
    globs: ["src/**/*.mbt"],
    exclude: [],
    context: [],
    thresholds,
    question: {
      instructions: "i",
      violation: "v",
      compliant: "c",
      insufficient_evidence: "u",
    },
    message: "m",
  }
}

///|
fn answer_of(choice : String, p : Double, confidence : Double) -> ChoiceAnswer {
  let rest = (1.0 - p) / 2.0
  let mut v = rest
  let mut c = rest
  let mut u = rest
  if choice == label_violation {
    v = p
  } else if choice == label_compliant {
    c = p
  } else {
    u = p
  }
  { choice, p_violation: v, p_compliant: c, p_insufficient: u, confidence }
}

///|
test "a double-star component matches zero or more path components" {
  assert_true(matches("src/**/*.mbt", "src/main.mbt"))
  assert_true(matches("src/**/*.mbt", "src/a/b/main.mbt"))
  assert_false(matches("src/**/*.mbt", "docs/main.mbt"))
  assert_false(matches("src/*.mbt", "src/a/main.mbt"))
  assert_true(matches("src/?.mbt", "src/a.mbt"))
  assert_false(matches("src/?.mbt", "src/ab.mbt"))
  assert_false(matches("src/**/*.mbt", "src/main.mbt.bak"))
}

///|
test "exclusion removes an otherwise selected path" {
  assert_true(selected(["src/**"], [], "src/a.py"))
  assert_false(selected(["src/**"], ["src/gen/**"], "src/gen/a.py"))
  assert_true(selected(["src/**"], ["src/gen/**"], "src/keep/a.py"))
}

///|
test "unsupported glob syntax is rejected instead of guessed at" {
  for pattern in ["", "/abs/x", "a/../b", "src/[a-z].mbt", "src/{a,b}.mbt", "src/a**/b", "src/a\\*.mbt"] {
    try validate_pattern(pattern) catch {
      _ => ()
    } noraise {
      _ => fail("expected '\{pattern}' to be rejected")
    }
  }
  validate_pattern("src/**/*.mbt")
}

///|
test "duplicate object keys are rejected rather than overwritten" {
  try parse_strict("{\"a\": 1, \"a\": 2}", "test") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected duplicate key rejection")
  }
  // Escaped spellings of the same key still collide.
  try parse_strict("{\"a\": 1, \"\\u0061\": 2}", "test") |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected escaped duplicate key rejection")
  }
  // A repeated key in different objects is fine.
  parse_strict("{\"x\": {\"a\": 1}, \"y\": {\"a\": 2}}", "test") |> ignore
  // A string value that looks like a key must not trigger a false positive.
  parse_strict("{\"a\": \"b\", \"c\": \"a\"}", "test") |> ignore
}

///|
test "a decisive answer clearing both thresholds decides the rule" {
  let rule = sample_rule(Advisory, { min_probability: 0.9, min_confidence: 0.8 })
  assert_eq(decide(rule, answer_of(label_violation, 0.9, 0.8)), DecideViolation)
  assert_eq(decide(rule, answer_of(label_compliant, 0.95, 0.9)), DecideCompliant)
}

///|
test "answers below either threshold route to review" {
  let rule = sample_rule(Advisory, { min_probability: 0.9, min_confidence: 0.8 })
  assert_eq(decide(rule, answer_of(label_violation, 0.89, 0.99)), DecideReview)
  assert_eq(decide(rule, answer_of(label_violation, 0.99, 0.79)), DecideReview)
  assert_eq(decide(rule, answer_of(label_compliant, 0.89, 0.99)), DecideReview)
}

///|
test "insufficient evidence is never compliance" {
  let rule = sample_rule(Advisory, { min_probability: 0.6, min_confidence: 0.1 })
  assert_eq(decide(rule, answer_of(label_insufficient, 0.99, 0.99)), DecideReview)
}

///|
fn result_of(status : ResultStatus, severity : Severity) -> RuleResult {
  {
    id: "r",
    status,
    severity,
    source: None,
    message: "m",
    paths: [],
    model: None,
    answer: None,
    detail: None,
  }
}

///|
fn report_of(
  results : Array[RuleResult],
  errors : Array[String],
) -> Report {
  {
    base: None,
    head: None,
    merge_base: None,
    config_ref: None,
    requested_model: default_model,
    results,
    errors,
  }
}

///|
test "conclusion precedence puts failures above verdicts" {
  let blocked = report_of([result_of(StatusViolation, Blocking)], [])
  assert_eq(blocked.conclusion(), ConcBlocked)
  assert_eq(blocked.exit_code(), 1)
  let advisory = report_of([result_of(StatusViolation, Advisory)], [])
  assert_eq(advisory.conclusion(), ConcAdvisory)
  assert_eq(advisory.exit_code(), 0)
  let review = report_of([result_of(StatusReview, Blocking)], [])
  assert_eq(review.conclusion(), ConcAdvisory)
  assert_eq(review.exit_code(), 0)
  let passing = report_of([result_of(StatusCompliant, Blocking)], [])
  assert_eq(passing.conclusion(), ConcPass)
  let skipped = report_of([result_of(StatusNotApplicable, Blocking)], [])
  assert_eq(skipped.conclusion(), ConcNotApplicable)
  assert_eq(skipped.exit_code(), 0)
  // An error outranks a blocking violation.
  let mixed = report_of(
    [result_of(StatusViolation, Blocking)],
    ["transport failed"],
  )
  assert_eq(mixed.conclusion(), ConcIncomplete)
  assert_eq(mixed.exit_code(), 2)
}

///|
test "a rule that could not be evaluated is judged by its own severity" {
  // A blocking rule must never pass unproven.
  let blocking = report_of([result_of(StatusError, Blocking)], [])
  assert_eq(blocking.conclusion(), ConcIncomplete)
  assert_eq(blocking.exit_code(), 2)
  // An advisory rule cannot stop a merge, and "could not look" is not graver
  // than "looked and found a violation", which is advisory.
  let advisory = report_of([result_of(StatusError, Advisory)], [])
  assert_eq(advisory.conclusion(), ConcAdvisory)
  assert_eq(advisory.exit_code(), 0)
  // One unevaluated blocking rule outranks any number of advisory ones.
  let mixed = report_of(
    [result_of(StatusError, Advisory), result_of(StatusError, Blocking)],
    [],
  )
  assert_eq(mixed.conclusion(), ConcIncomplete)
  // An unevaluated advisory rule never counts as a pass.
  let with_compliant = report_of(
    [result_of(StatusCompliant, Advisory), result_of(StatusError, Advisory)],
    [],
  )
  assert_eq(with_compliant.conclusion(), ConcAdvisory)
  // A run-level failure stays unconditional regardless of severity.
  let run_level = report_of([result_of(StatusError, Advisory)], ["transport failed"])
  assert_eq(run_level.conclusion(), ConcIncomplete)
  assert_eq(run_level.exit_code(), 2)
}

///|
test "annotation escaping cannot emit a second workflow command" {
  let hostile = "a\nb::error::boom%s\rc"
  let escaped = escape_annotation_data(hostile)
  assert_false(escaped.contains("\n"))
  assert_false(escaped.contains("\r"))
  assert_true(escaped.contains("%0A"))
  assert_true(escaped.contains("%25"))
  let property = escape_annotation_property("a:b,c")
  assert_eq(property, "a%3Ab%2Cc")
}

///|
test "a blocking rule must state its own thresholds" {
  let text =
    #|{"version":1,"rules":[{"id":"a","severity":"blocking","globs":["src/**"],
    #|"question":{"type":"choice","instructions":"i","criteria":{"violation":"v",
    #|"compliant":"c","insufficient_evidence":"u"}},"message":"m"}]}
  try parse_config(text) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected missing thresholds to be rejected")
  }
}

///|
test "an advisory rule without thresholds gets the documented defaults" {
  let text =
    #|{"version":1,"rules":[{"id":"a","globs":["src/**"],
    #|"question":{"type":"choice","instructions":"i","criteria":{"violation":"v",
    #|"compliant":"c","insufficient_evidence":"u"}},"message":"m"}]}
  let config = parse_config(text)
  assert_eq(config.model, default_model)
  assert_eq(config.rules[0].severity, Advisory)
  assert_eq(config.rules[0].thresholds.min_probability, default_min_probability)
  assert_eq(config.rules[0].thresholds.min_confidence, default_min_confidence)
}

///|
test "a response must answer exactly the asked questions" {
  let body =
    #|{"model":"jev-1.13.0","usage":{"input_tokens":3},"answers":{"a":{"type":"choice",
    #|"choice":"violation","probabilities":{"violation":0.9,"compliant":0.05,
    #|"insufficient_evidence":0.05},"confidence":0.8}}}
  let decoded = decode_response(body, ["a"])
  assert_eq(decoded.model, "jev-1.13.0")
  assert_eq(decoded.answers["a"].choice, label_violation)
  try decode_response(body, ["a", "b"]) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected a missing answer to be rejected")
  }
}

///|
test "a chosen label must hold a maximal probability" {
  let body =
    #|{"model":"m","usage":{},"answers":{"a":{"type":"choice","choice":"compliant",
    #|"probabilities":{"violation":0.8,"compliant":0.1,"insufficient_evidence":0.1},
    #|"confidence":0.9}}}
  try decode_response(body, ["a"]) |> ignore catch {
    _ => ()
  } noraise {
    _ => fail("expected a non-maximal choice to be rejected")
  }
}

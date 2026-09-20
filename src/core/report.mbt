///|
/// Report schema version emitted in JSON output.
pub let report_schema_version : Int = 1

///|
pub fn render_report(report : Report, format : OutputFormat) -> String {
  match format {
    FormatText => render_text(report)
    FormatJson => render_json(report)
    FormatGithub => render_github(report)
  }
}

///|
fn render_text(report : Report) -> String {
  let out = StringBuilder()
  let mut counts_violation = 0
  let mut counts_review = 0
  let mut counts_compliant = 0
  let mut counts_skipped = 0
  let mut counts_error = 0
  for result in report.results {
    match result.status {
      StatusViolation => counts_violation += 1
      StatusReview => counts_review += 1
      StatusCompliant => counts_compliant += 1
      StatusNotApplicable => counts_skipped += 1
      StatusError => counts_error += 1
    }
    let headline = match result.status {
      StatusViolation =>
        if result.severity == Blocking {
          "BLOCKING POSSIBLE VIOLATION"
        } else {
          "ADVISORY POSSIBLE VIOLATION"
        }
      StatusReview => "REVIEW NEEDED"
      StatusCompliant => "compliant"
      StatusNotApplicable => "not applicable"
      StatusError => "ERROR"
    }
    out.write_string("\{headline}: \{sanitize_line(result.id)}\n")
    match result.source {
      Some(source) => out.write_string("  source: \{sanitize_line(source)}\n")
      None => ()
    }
    if !result.paths.is_empty() {
      out.write_string("  paths: \{join_paths(result.paths)}\n")
    }
    match result.answer {
      Some(answer) => {
        let model = match result.model {
          Some(name) => sanitize_line(name)
          None => "unknown"
        }
        out.write_string(
          "  choice=\{sanitize_line(answer.choice)} p=\{fmt(answer.probability_of(answer.choice))} confidence=\{fmt(answer.confidence)} model=\{model}\n",
        )
      }
      None => ()
    }
    // The message is pre-authored finding text, so it must not appear under a
    // compliant result, where a log reader would read it as a finding.
    if result.status is (StatusViolation | StatusReview | StatusError) {
      out.write_string("  \{sanitize_line(result.message)}\n")
    }
    match result.detail {
      Some(detail) => out.write_string("  \{sanitize_line(detail)}\n")
      None => ()
    }
  }
  for err in report.errors {
    out.write_string("ERROR: \{sanitize_line(err)}\n")
  }
  let conclusion = report.conclusion()
  out.write_string(
    "summary: violations=\{counts_violation} review=\{counts_review} compliant=\{counts_compliant} not_applicable=\{counts_skipped} errors=\{counts_error + report.errors.length()}\n",
  )
  out.write_string(
    "conclusion: \{conclusion.label()} (exit \{report.exit_code()})\n",
  )
  out.to_string()
}

///|
fn join_paths(paths : Array[String]) -> String {
  let out = StringBuilder()
  for i, path in paths {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(sanitize_line(path))
  }
  out.to_string()
}

///|
/// Renders a probability or confidence with three decimals.
fn fmt(value : Double) -> String {
  let scaled = (value * 1000.0).round().to_int()
  let whole = scaled / 1000
  let frac = scaled % 1000
  let digits = "\{frac}"
  let padded = if frac >= 100 {
    digits
  } else if frac >= 10 {
    "0" + digits
  } else {
    "00" + digits
  }
  "\{whole}.\{padded}"
}

///|
fn opt_json(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
fn render_json(report : Report) -> String {
  let results : Array[Json] = []
  for result in report.results {
    let paths : Array[Json] = []
    for path in result.paths {
      paths.push(Json::string(path))
    }
    results.push(
      Json::object({
        "id": Json::string(result.id),
        "status": Json::string(result.status.label()),
        "severity": Json::string(result.severity.label()),
        "source": opt_json(result.source),
        "message": Json::string(result.message),
        "paths": Json::array(paths),
        "model": opt_json(result.model),
        "answer": match result.answer {
          Some(answer) => answer.to_json_value()
          None => Json::null()
        },
        "detail": match result.detail {
          Some(detail) => Json::string(sanitize_line(detail))
          None => Json::null()
        },
      }),
    )
  }
  let errors : Array[Json] = []
  for err in report.errors {
    errors.push(Json::string(sanitize_line(err)))
  }
  Json::object({
    "schema_version": Json::number(report_schema_version.to_double()),
    "base": opt_json(report.base),
    "head": opt_json(report.head),
    "merge_base": opt_json(report.merge_base),
    "config_ref": opt_json(report.config_ref),
    "requested_model": Json::string(report.requested_model),
    "conclusion": Json::string(report.conclusion().label()),
    "exit_code": Json::number(report.exit_code().to_double()),
    "results": Json::array(results),
    "errors": Json::array(errors),
  }).stringify() + "\n"
}

///|
/// Escapes an annotation message body. Without this a repository string could
/// terminate the line and emit a second workflow command.
pub fn escape_annotation_data(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    match ch {
      '%' => out.write_string("%25")
      '\r' => out.write_string("%0D")
      '\n' => out.write_string("%0A")
      _ =>
        if ch.to_int() < 0x20 || ch.to_int() == 0x7f {
          out.write_string(sanitize_line(ch.to_string()))
        } else {
          out.write_char(ch)
        }
    }
  }
  out.to_string()
}

///|
/// Escapes an annotation property value (stricter: `:` and `,` delimit
/// properties).
pub fn escape_annotation_property(text : String) -> String {
  let out = StringBuilder()
  for ch in escape_annotation_data(text) {
    match ch {
      ':' => out.write_string("%3A")
      ',' => out.write_string("%2C")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn render_github(report : Report) -> String {
  let out = StringBuilder()
  for result in report.results {
    let title = escape_annotation_property("moongate: \{result.id}")
    let detail = StringBuilder()
    // The runner's own verdict leads, because it is not the model's choice:
    // an answer below a threshold is a review no matter which label it picked,
    // and review and advisory violation both render as `::warning`. Without
    // this a reader cannot tell that the runner rejected the verdict.
    detail.write_string(
      match result.status {
        StatusViolation => "[violation] "
        StatusReview => "[needs review] "
        StatusError => "[not evaluated] "
        _ => ""
      },
    )
    detail.write_string(result.message)
    match result.source {
      Some(source) => detail.write_string(" (source: \{source})")
      None => ()
    }
    if !result.paths.is_empty() {
      detail.write_string(" [paths: \{join_paths(result.paths)}]")
    }
    match result.answer {
      Some(answer) =>
        detail.write_string(
          " [choice=\{answer.choice} p=\{fmt(answer.probability_of(answer.choice))} confidence=\{fmt(answer.confidence)}]",
        )
      None => ()
    }
    match result.detail {
      Some(reason) => detail.write_string(" [\{reason}]")
      None => ()
    }
    let body = escape_annotation_data(detail.to_string())
    match result.status {
      StatusViolation =>
        if result.severity == Blocking {
          out.write_string("::error title=\{title}::\{body}\n")
        } else {
          out.write_string("::warning title=\{title}::\{body}\n")
        }
      StatusReview => out.write_string("::warning title=\{title}::\{body}\n")
      // A rule that could not be evaluated is as loud as its severity allows,
      // matching the conclusion: an advisory rule never fails the job.
      StatusError =>
        if result.severity == Blocking {
          out.write_string("::error title=\{title}::\{body}\n")
        } else {
          out.write_string("::warning title=\{title}::\{body}\n")
        }
      _ => ()
    }
  }
  for err in report.errors {
    out.write_string(
      "::error title=\{escape_annotation_property("moongate")}::\{escape_annotation_data(err)}\n",
    )
  }
  out.write_string(
    "::notice title=moongate::conclusion \{report.conclusion().label()} (exit \{report.exit_code()})\n",
  )
  out.to_string()
}

///|
/// Renders the `validate` outcome.
pub fn render_validation(
  rule_count : Int?,
  errors : Array[String],
  format : OutputFormat,
) -> String {
  let valid = rule_count is Some(_)
  match format {
    FormatJson => {
      let items : Array[Json] = []
      for err in errors {
        items.push(Json::string(sanitize_line(err)))
      }
      Json::object({
        "valid": Json::boolean(valid),
        "rule_count": match rule_count {
          Some(n) => Json::number(n.to_double())
          None => Json::null()
        },
        "errors": Json::array(items),
      }).stringify() + "\n"
    }
    FormatText =>
      match rule_count {
        Some(n) => "Configuration is valid (\{n} rules).\n"
        None => {
          let out = StringBuilder()
          for err in errors {
            out.write_string("ERROR: \{sanitize_line(err)}\n")
          }
          out.to_string()
        }
      }
    FormatGithub =>
      match rule_count {
        Some(n) =>
          "::notice title=moongate::configuration is valid (\{n} rules)\n"
        None => {
          let out = StringBuilder()
          for err in errors {
            out.write_string(
              "::error title=moongate::\{escape_annotation_data(err)}\n",
            )
          }
          out.to_string()
        }
      }
  }
}

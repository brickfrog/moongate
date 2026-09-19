///|
/// Model pinned by default. Changing it is an explicit configuration act,
/// because thresholds are only meaningful relative to one model.
pub let default_model : String = "jev-1.13.0"

///|
/// Default advisory thresholds. Blocking rules must state their own.
pub let default_min_probability : Double = 0.90

///|
pub let default_min_confidence : Double = 0.80

///|
/// Byte ceiling for a configuration file.
pub let max_config_bytes : Int = 1048576

///|
/// Parses and fully validates `.moongate.json`.
pub fn parse_config(text : String) -> Config raise {
  let root = parse_strict(text, "configuration")
  let obj = expect_object(root, "configuration")
  reject_unknown(obj, ["$schema", "version", "model", "rules"], "configuration")
  let version = expect_int(field(obj, "version", "configuration"), "version")
  if version != 1 {
    raise GateError("Unsupported configuration version \{version}; expected 1.")
  }
  let model = match obj.get("model") {
    None => default_model
    Some(value) => {
      let name = expect_string(value, "model")
      if name.trim(chars=" \t\r\n").is_empty() {
        raise GateError("Configuration 'model' must not be empty.")
      }
      name
    }
  }
  let rules_json = expect_array(
    field(obj, "rules", "configuration"),
    "rules",
  )
  let rules : Array[Rule] = []
  let seen : Map[String, Unit] = Map([])
  for entry in rules_json {
    let rule = parse_rule(entry)
    if seen.contains(rule.id) {
      raise GateError("Duplicate rule id '\{sanitize_line(rule.id)}'.")
    }
    seen[rule.id] = ()
    rules.push(rule)
  }
  { version, model, rules }
}

///|
fn parse_rule(entry : Json) -> Rule raise {
  let obj = expect_object(entry, "rule")
  reject_unknown(
    obj,
    [
      "id", "source", "severity", "globs", "exclude", "context", "thresholds",
      "question", "message",
    ],
    "rule",
  )
  let id = expect_string(field(obj, "id", "rule"), "rule id")
  validate_rule_id(id)
  let ctx = "rule '\{sanitize_line(id)}'"
  let source = match obj.get("source") {
    None => None
    Some(value) => {
      let text = expect_string(value, "\{ctx} source")
      if text.is_empty() {
        raise GateError("\{ctx}: 'source' must not be empty when present.")
      }
      Some(text)
    }
  }
  let severity = match obj.get("severity") {
    None => Advisory
    Some(value) =>
      match expect_string(value, "\{ctx} severity") {
        "advisory" => Advisory
        "blocking" => Blocking
        other =>
          raise GateError(
            "\{ctx}: unknown severity '\{sanitize_line(other)}'. Expected advisory or blocking.",
          )
      }
  }
  let globs = string_patterns(field(obj, "globs", "\{ctx}"), "\{ctx} globs")
  if globs.is_empty() {
    raise GateError("\{ctx}: 'globs' must not be empty.")
  }
  let exclude = match obj.get("exclude") {
    None => []
    Some(value) => string_patterns(value, "\{ctx} exclude")
  }
  let context : Array[String] = match obj.get("context") {
    None => []
    Some(value) => {
      let out : Array[String] = []
      for item in expect_array(value, "\{ctx} context") {
        let path = expect_string(item, "\{ctx} context entry")
        validate_rel_path(path, "\{ctx} context")
        out.push(path)
      }
      out
    }
  }
  let thresholds = match obj.get("thresholds") {
    None =>
      if severity == Blocking {
        raise GateError(
          "\{ctx}: a blocking rule must declare explicit thresholds.",
        )
      } else {
        { min_probability: default_min_probability,
          min_confidence: default_min_confidence }
      }
    Some(value) => parse_thresholds(value, ctx)
  }
  let question = parse_question(field(obj, "question", "\{ctx}"), ctx)
  let message = expect_string(field(obj, "message", "\{ctx}"), "\{ctx} message")
  if message.is_empty() {
    raise GateError("\{ctx}: 'message' must not be empty.")
  }
  { id, source, severity, globs, exclude, context, thresholds, question, message }
}

///|
fn parse_thresholds(value : Json, ctx : String) -> Thresholds raise {
  let obj = expect_object(value, "\{ctx} thresholds")
  reject_unknown(obj, ["min_probability", "min_confidence"], "\{ctx} thresholds")
  let p = expect_number(
    field(obj, "min_probability", "\{ctx} thresholds"),
    "\{ctx} min_probability",
  )
  let c = expect_number(
    field(obj, "min_confidence", "\{ctx} thresholds"),
    "\{ctx} min_confidence",
  )
  if p.is_nan() || p.is_inf() || p <= 0.5 || p > 1.0 {
    raise GateError("\{ctx}: 'min_probability' must be in (0.5, 1].")
  }
  if c.is_nan() || c.is_inf() || c < 0.0 || c > 1.0 {
    raise GateError("\{ctx}: 'min_confidence' must be in [0, 1].")
  }
  { min_probability: p, min_confidence: c }
}

///|
fn parse_question(value : Json, ctx : String) -> Question raise {
  let obj = expect_object(value, "\{ctx} question")
  reject_unknown(obj, ["type", "instructions", "criteria"], "\{ctx} question")
  let kind = expect_string(field(obj, "type", "\{ctx} question"), "\{ctx} question type")
  if kind != "choice" {
    raise GateError(
      "\{ctx}: unsupported question type '\{sanitize_line(kind)}'. Only 'choice' is supported.",
    )
  }
  let instructions = expect_string(
    field(obj, "instructions", "\{ctx} question"),
    "\{ctx} instructions",
  )
  if instructions.trim(chars=" \t\r\n").is_empty() {
    raise GateError("\{ctx}: 'instructions' must not be empty.")
  }
  let criteria = expect_object(
    field(obj, "criteria", "\{ctx} question"),
    "\{ctx} criteria",
  )
  reject_unknown(
    criteria,
    [label_violation, label_compliant, label_insufficient],
    "\{ctx} criteria",
  )
  let read = fn(key : String) -> String raise {
    let text = expect_string(field(criteria, key, "\{ctx} criteria"), "\{ctx} \{key} criterion")
    if text.trim(chars=" \t\r\n").is_empty() {
      raise GateError("\{ctx}: criterion '\{key}' must not be empty.")
    }
    text
  }
  {
    instructions,
    violation: read(label_violation),
    compliant: read(label_compliant),
    insufficient_evidence: read(label_insufficient),
  }
}

///|
fn validate_rule_id(id : String) -> Unit raise {
  let show = sanitize_line(id)
  let chars = id.to_array()
  if chars.length() == 0 || chars.length() > 64 {
    raise GateError("Rule id '\{show}' must be 1-64 characters.")
  }
  let first = chars[0]
  if !(first >= 'a' && first <= 'z') {
    raise GateError("Rule id '\{show}' must start with a lowercase letter.")
  }
  for ch in chars {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_'
    if !ok {
      raise GateError(
        "Rule id '\{show}' may only contain lowercase letters, digits and underscores.",
      )
    }
  }
}

///|
fn string_patterns(value : Json, what : String) -> Array[String] raise {
  let out : Array[String] = []
  for item in expect_array(value, what) {
    let pattern = expect_string(item, what)
    validate_pattern(pattern)
    out.push(pattern)
  }
  out
}

///|
fn field(obj : Map[String, Json], key : String, what : String) -> Json raise {
  match obj.get(key) {
    Some(value) => value
    None => raise GateError("Missing '\{key}' in \{what}.")
  }
}

///|
fn reject_unknown(
  obj : Map[String, Json],
  allowed : Array[String],
  what : String,
) -> Unit raise {
  for key, _ in obj {
    let mut ok = false
    for name in allowed {
      if name == key {
        ok = true
        break
      }
    }
    if !ok {
      raise GateError("Unknown field '\{sanitize_line(key)}' in \{what}.")
    }
  }
}

///|
fn expect_object(value : Json, what : String) -> Map[String, Json] raise {
  match value {
    Json::Object(obj) => obj
    _ => raise GateError("Expected \{what} to be an object.")
  }
}

///|
fn expect_array(value : Json, what : String) -> Array[Json] raise {
  match value {
    Json::Array(items) => items
    _ => raise GateError("Expected \{what} to be an array.")
  }
}

///|
fn expect_string(value : Json, what : String) -> String raise {
  match value {
    Json::String(text) => text
    _ => raise GateError("Expected \{what} to be a string.")
  }
}

///|
fn expect_number(value : Json, what : String) -> Double raise {
  match value {
    Json::Number(v, ..) => v
    _ => raise GateError("Expected \{what} to be a number.")
  }
}

///|
fn expect_int(value : Json, what : String) -> Int raise {
  let v = expect_number(value, what)
  let i = v.to_int()
  if i.to_double() != v {
    raise GateError("Expected \{what} to be an integer.")
  }
  i
}

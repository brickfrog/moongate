///|
/// Validates a configuration glob pattern.
///
/// Patterns are deliberately a small, total language: complete root-relative
/// paths, `/` separators, `*` and `?` inside one component, and `**` as a
/// whole component. They are neither shell words nor Git pathspecs, so
/// brackets, braces and backslash escapes are rejected rather than guessed at.
pub fn validate_pattern(pattern : String) -> Unit raise {
  if pattern.is_empty() {
    raise GateError("Empty glob pattern.")
  }
  let show = sanitize_line(pattern)
  for ch in pattern {
    match ch {
      '\u{0}' => raise GateError("Glob '\{show}' contains a NUL character.")
      '\\' | '[' | ']' | '{' | '}' =>
        raise GateError(
          "Glob '\{show}' uses unsupported syntax '\{ch}'. Only *, ? and ** are supported.",
        )
      _ => ()
    }
  }
  if pattern.has_prefix("/") {
    raise GateError("Glob '\{show}' must be repository-root-relative.")
  }
  for comp in pattern.split("/") {
    let comp = comp.to_owned()
    if comp.is_empty() {
      raise GateError("Glob '\{show}' contains an empty path component.")
    }
    if comp == "." || comp == ".." {
      raise GateError("Glob '\{show}' contains a '\{comp}' component.")
    }
    if comp.contains("**") && comp != "**" {
      raise GateError(
        "Glob '\{show}' embeds '**' inside a component; '**' must be a whole component.",
      )
    }
  }
}

///|
/// Validates an exact repository-root-relative path (context entries and
/// paths read out of Git).
pub fn validate_rel_path(path : String, what : String) -> Unit raise {
  let show = sanitize_line(path)
  if path.is_empty() {
    raise GateError("Empty \{what} path.")
  }
  if path.contains_char('\u{0}') {
    raise GateError("\{what} path '\{show}' contains a NUL character.")
  }
  if path.has_prefix("/") {
    raise GateError("\{what} path '\{show}' must be repository-root-relative.")
  }
  for comp in path.split("/") {
    let comp = comp.to_owned()
    if comp.is_empty() {
      raise GateError("\{what} path '\{show}' contains an empty component.")
    }
    if comp == "." || comp == ".." {
      raise GateError("\{what} path '\{show}' contains a '\{comp}' component.")
    }
  }
}

///|
/// Matches a complete root-relative path against a validated pattern.
///
/// A `**` component matches zero or more path components, so `src/**/*.mbt`
/// matches `src/main.mbt` as well as `src/a/b/main.mbt`.
pub fn matches(pattern : String, path : String) -> Bool {
  let pats = split_components(pattern)
  let parts = split_components(path)
  let np = pats.length()
  let ns = parts.length()
  // dp[j] == "the first i path components are matched by the first j pattern
  // components", rolled over i.
  let dp = Array::make(np + 1, false)
  dp[0] = true
  for j = 1; j <= np; j = j + 1 {
    dp[j] = dp[j - 1] && pats[j - 1] == "**"
  }
  for i = 1; i <= ns; i = i + 1 {
    let prev = dp.copy()
    dp[0] = false
    for j = 1; j <= np; j = j + 1 {
      dp[j] = if pats[j - 1] == "**" {
        dp[j - 1] || prev[j]
      } else {
        prev[j - 1] && match_component(pats[j - 1], parts[i - 1])
      }
    }
  }
  dp[np]
}

///|
fn split_components(text : String) -> Array[String] {
  let out : Array[String] = []
  for comp in text.split("/") {
    out.push(comp.to_owned())
  }
  out
}

///|
/// Matches one path component against a pattern component containing `*`
/// (zero or more characters) and `?` (exactly one character).
fn match_component(pattern : String, text : String) -> Bool {
  let p = pattern.to_array()
  let s = text.to_array()
  let np = p.length()
  let ns = s.length()
  let dp = Array::make(np + 1, false)
  dp[0] = true
  for j = 1; j <= np; j = j + 1 {
    dp[j] = dp[j - 1] && p[j - 1] == '*'
  }
  for i = 1; i <= ns; i = i + 1 {
    let prev = dp.copy()
    dp[0] = false
    for j = 1; j <= np; j = j + 1 {
      dp[j] = if p[j - 1] == '*' {
        dp[j - 1] || prev[j]
      } else if p[j - 1] == '?' {
        prev[j - 1]
      } else {
        prev[j - 1] && p[j - 1] == s[i - 1]
      }
    }
  }
  dp[np]
}

///|
/// A path is selected when at least one include matches and no exclude does.
pub fn selected(
  includes : Array[String],
  excludes : Array[String],
  path : String,
) -> Bool {
  let mut hit = false
  for pattern in includes {
    if matches(pattern, path) {
      hit = true
      break
    }
  }
  if !hit {
    return false
  }
  for pattern in excludes {
    if matches(pattern, path) {
      return false
    }
  }
  true
}

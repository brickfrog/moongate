///|
/// Maximum accepted JSON nesting depth for every untrusted JSON input.
pub let max_json_depth : Int = 32

///|
/// Parses JSON with a bounded depth and rejects duplicate object keys.
///
/// Core's parser silently keeps the last occurrence of a duplicated key, which
/// would let a configuration overwrite a policy field (for example `severity`)
/// without any diagnostic. Every untrusted JSON input goes through here.
pub fn parse_strict(text : String, what : String) -> Json raise {
  let value = try @json.parse(text, max_nesting_depth=max_json_depth) catch {
    err =>
      raise GateError("Invalid \{what} JSON: \{sanitize_line(err.to_string())}")
  }
  check_unique_keys(text, what)
  value
}

///|
/// Rejects duplicate keys inside any object of an already-valid JSON text.
///
/// Keys are compared after escape decoding, so `"a"` and `"\u0061"` collide.
pub fn check_unique_keys(text : String, what : String) -> Unit raise {
  let cs = text.to_array()
  let n = cs.length()
  // `Some(seen)` marks an object scope, `None` an array scope.
  let stack : Array[Map[String, Unit]?] = []
  let mut expect_key = false
  let mut i = 0
  while i < n {
    let c = cs[i]
    if c == '{' {
      stack.push(Some(Map([])))
      expect_key = true
      i += 1
    } else if c == '[' {
      stack.push(None)
      expect_key = false
      i += 1
    } else if c == '}' || c == ']' {
      if stack.length() > 0 {
        stack.pop() |> ignore
      }
      expect_key = false
      i += 1
    } else if c == ',' {
      expect_key = stack.length() > 0 && stack[stack.length() - 1] is Some(_)
      i += 1
    } else if c == ':' {
      expect_key = false
      i += 1
    } else if c == '"' {
      let stop = scan_string_end(cs, i)
      if expect_key {
        let raw = String::from_array(cs[i:stop])
        let key = match @json.parse(raw) {
          Json::String(s) => s
          _ => raise GateError("Invalid \{what} JSON: malformed object key.")
        }
        match stack[stack.length() - 1] {
          Some(seen) => {
            if seen.contains(key) {
              raise GateError(
                "Duplicate key '\{sanitize_line(key)}' in \{what} JSON.",
              )
            }
            seen[key] = ()
          }
          None => ()
        }
        expect_key = false
      }
      i = stop
    } else {
      i += 1
    }
  }
}

///|
/// Returns the index just past the closing quote of the string starting at
/// `start` (which must be the opening quote).
fn scan_string_end(cs : Array[Char], start : Int) -> Int {
  let n = cs.length()
  let mut i = start + 1
  while i < n {
    let c = cs[i]
    if c == '\\' {
      i += 2
    } else if c == '"' {
      return i + 1
    } else {
      i += 1
    }
  }
  n
}

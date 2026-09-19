///|
/// Controlled, user-facing failure. The payload is always safe to print: it
/// never contains credentials, request bodies, or raw repository content.
pub(all) suberror GateError {
  GateError(String)
}

///|
pub impl Show for GateError with fn output(self : GateError, logger) {
  let GateError(msg) = self
  logger.write_string(msg)
}

///|
/// Renders any error as a safe single-line diagnostic.
///
/// `GateError` payloads are printed verbatim. Every other error is reduced to
/// its constructor-level description, because foreign errors (transport, OS)
/// may embed request or environment details.
pub fn safe_message(err : Error) -> String {
  match err {
    GateError(msg) => sanitize_line(msg)
    _ => sanitize_line(err.to_string())
  }
}

///|
/// Sanitizes multi-line help or usage text for a terminal.
///
/// Newlines are preserved for readability, but no line may begin with `::`,
/// which GitHub Actions would interpret as a workflow command.
pub fn sanitize_block(text : String) -> String {
  let out = StringBuilder()
  let mut first = true
  for line in text.split("\n") {
    if !first {
      out.write_char('\n')
    }
    first = false
    let clean = sanitize_line(line.to_owned())
    if clean.has_prefix("::") {
      out.write_char(' ')
    }
    out.write_string(clean)
  }
  out.to_string()
}

///|
/// Replaces control characters so a diagnostic can never emit a second line,
/// a workflow command, or a terminal escape sequence.
pub fn sanitize_line(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    let code = ch.to_int()
    if code < 0x20 || code == 0x7f {
      out.write_string(
        match ch {
          '\n' => "\\n"
          '\r' => "\\r"
          '\t' => "\\t"
          _ => "\\x" + pad_hex(code)
        },
      )
    } else {
      out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn pad_hex(code : Int) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  out.write_char(digits.get_char((code >> 4) & 0xf).unwrap())
  out.write_char(digits.get_char(code & 0xf).unwrap())
  out.to_string()
}

// Host services the runner needs: process execution, HTTPS, the filesystem,
// standard output, the environment, and process exit.
//
// Two implementations exist. `host_native.mbt` wraps `moonbitlang/async` for
// the native binary; `host_js.mbt` wraps Node for the `--target js` bundle
// shipped as a GitHub Action. Everything above this package is target-neutral.

///|
pub(all) suberror HostError {
  HostError(String)
}

///|
/// Result of running a child process. `stdout` stays bytes because Git output
/// is not always text; `stderr` is only used for diagnostics.
pub(all) struct CommandResult {
  code : Int
  stdout : Bytes
  stderr : String
}

///|
/// Result of one HTTPS request. The body is capped by the caller's limit.
pub(all) struct HttpResponse {
  status : Int
  request_id : String
  body : Bytes
}

///|
/// What a path is, without following symlinks.
pub(all) enum PathKind {
  Regular
  Other
  Missing
} derive(Eq)

///|
/// The host services the runner needs, supplied by whichever backend the
/// executable links. A record of functions rather than target-gated files:
/// `moon` resolves imports per package, not per target, so the backend has to
/// live in its own package.
pub(all) struct Host {
  run_command : async (String, Array[String], Map[String, String], Int, Int) -> CommandResult raise
  post_json : async (String, String, Array[(String, String)], String, Int, Int) -> HttpResponse raise
  path_kind : async (String) -> PathKind raise
  file_size : async (String) -> Int64 raise
  read_file : async (String) -> Bytes raise
  realpath : async (String) -> String raise
  current_dir : () -> String?
  env_vars : () -> Map[String, String]
  args : () -> Array[String]
  write_stdout : async (String) -> Unit
  write_stderr : async (String) -> Unit
  exit : (Int) -> Unit
}

///|
let installed : Ref[Host?] = { val: None }

///|
/// Installs the backend. The executable's entry point calls this first.
pub fn install(host : Host) -> Unit {
  installed.val = Some(host)
}

///|
/// The installed backend. Reaching this before `install` is a programming
/// error in the executable, not a condition the runner can recover from.
pub fn current() -> Host raise {
  match installed.val {
    Some(host) => host
    None => raise HostError("No host backend was installed.")
  }
}

///|
/// Decodes standard base64. The JS bridge encodes binary payloads this way, so
/// no byte array has to cross the FFI boundary.
pub fn decode_base64(text : String) -> Bytes raise {
  let out = FixedArray::make(text.length() / 4 * 3 + 3, b'\x00')
  let mut length = 0
  let mut acc = 0
  let mut bits = 0
  for ch in text {
    let value = if ch >= 'A' && ch <= 'Z' {
      ch.to_int() - 'A'.to_int()
    } else if ch >= 'a' && ch <= 'z' {
      ch.to_int() - 'a'.to_int() + 26
    } else if ch >= '0' && ch <= '9' {
      ch.to_int() - '0'.to_int() + 52
    } else if ch == '+' {
      62
    } else if ch == '/' {
      63
    } else if ch == '=' || ch == '\n' || ch == '\r' {
      continue
    } else {
      raise HostError("Malformed base64 in a host response.")
    }
    acc = acc * 64 + value
    bits += 6
    if bits >= 8 {
      bits -= 8
      out[length] = ((acc >> bits) & 0xff).to_byte()
      length += 1
      acc = acc & ((1 << bits) - 1)
    }
  }
  out.unsafe_reinterpret_as_bytes()[:length].to_bytes()
}

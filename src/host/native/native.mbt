// Native host services, backed by moonbitlang/async.

///|
async fn run_command(
  program : String,
  args : Array[String],
  env : Map[String, String],
  timeout_ms~ : Int,
  max_output_bytes~ : Int,
) -> @host.CommandResult raise {
  let cmd = @shell.Cmd(
    program,
    args,
    env~,
    inherit_env=false,
    stdout=@shell.Redirect::Capture,
    stderr=@shell.Redirect::Capture,
  )
  let output = try cmd.output(timeout_ms~, max_output_bytes~) catch {
    err => raise @host.HostError("Running '\{program}' failed: \{err}")
  }
  {
    code: output.exit_code(),
    stdout: output.stdout_bytes(),
    stderr: output.stderr(),
  }
}

///|
/// Posts a JSON body. Redirects are never followed and TLS always verifies
/// against the system trust store.
async fn post_json(
  origin : String,
  path : String,
  headers : Array[(String, String)],
  body : String,
  timeout_ms~ : Int,
  max_response_bytes~ : Int,
) -> @host.HttpResponse raise {
  @async.with_timeout(timeout_ms, async fn() {
    let table : Map[@http.CaseInsensitiveString, String] = Map([])
    for header in headers {
      table[@http.CaseInsensitiveString(header.0)] = header.1
    }
    let client = try @http.Client(origin, trust=@tls.TrustedRoot::SystemRoot) catch {
      err => raise @host.HostError("Cannot reach the evaluation API: \{err}")
    }
    errdefer client.close()
    let response = try client.post(path, body, extra_headers=table) catch {
      err => raise @host.HostError("Evaluation request failed: \{err}")
    }
    let request_id = match
      response.headers.get(@http.CaseInsensitiveString("x-typesafe-request-id")) {
      Some(value) => value
      None => ""
    }
    // Chunks are accumulated as bytes and decoded once by the caller: a
    // multi-byte sequence split across two reads is valid UTF-8 overall but
    // not per chunk.
    let chunks : Array[Bytes] = []
    let mut total = 0
    while true {
      let chunk = try client.read_some() catch {
        err => raise @host.HostError("Reading the evaluation response failed: \{err}")
      }
      match chunk {
        None => break
        Some(bytes) => {
          total += bytes.length()
          if total > max_response_bytes {
            raise @host.HostError("Evaluation response exceeds its size limit.")
          }
          chunks.push(bytes)
        }
      }
    }
    client.close()
    let merged = FixedArray::make(total, b'\x00')
    let mut at = 0
    for chunk in chunks {
      merged.blit_from_bytes(at, chunk, 0, chunk.length())
      at += chunk.length()
    }
    { status: response.code, request_id, body: merged.unsafe_reinterpret_as_bytes() }
  })
}

///|
async fn path_kind(path : String) -> @host.PathKind raise {
  let kind = try @fs.kind(path, follow_symlink=false) catch {
    _ => return @host.Missing
  }
  if kind == @fs.FileKind::Regular {
    @host.Regular
  } else {
    @host.Other
  }
}

///|
async fn file_size(path : String) -> Int64 raise {
  try @fs.file_size(path) catch {
    err => raise @host.HostError("Cannot measure '\{path}': \{err}")
  }
}

///|
async fn read_file(path : String) -> Bytes raise {
  try @fs.read_file(path).binary() catch {
    err => raise @host.HostError("Cannot read '\{path}': \{err}")
  }
}

///|
async fn realpath(path : String) -> String raise {
  try @fs.realpath(path) catch {
    _ => path
  }
}

///|
fn current_dir() -> String? {
  @env.current_dir()
}

///|
fn env_vars() -> Map[String, String] {
  @env.get_env_vars()
}

///|
fn env_var(name : String) -> String? {
  @env.get_env_var(name)
}

///|
fn args() -> Array[String] {
  @env.args()
}

///|
async fn write_stdout(text : String) -> Unit {
  try @stdio.stdout.write(text) catch {
    _ => ()
  }
}

///|
async fn write_stderr(text : String) -> Unit {
  try @stdio.stderr.write(text) catch {
    _ => ()
  }
}

///|
fn exit(code : Int) -> Unit {
  @sys.exit(code)
}

///|
/// The backend for this target.
pub fn host() -> @host.Host {
  {
    run_command: (program, args, env, timeout_ms, max_output_bytes) =>
      run_command(program, args, env, timeout_ms~, max_output_bytes~),
    post_json: (origin, path, headers, body, timeout_ms, max_response_bytes) =>
      post_json(origin, path, headers, body, timeout_ms~, max_response_bytes~),
    path_kind: path => path_kind(path),
    file_size: path => file_size(path),
    read_file: path => read_file(path),
    realpath: path => realpath(path),
    current_dir: () => current_dir(),
    env_vars: () => env_vars(),
    args: () => args(),
    write_stdout: text => write_stdout(text),
    write_stderr: text => write_stderr(text),
    exit: code => exit(code),
  }
}

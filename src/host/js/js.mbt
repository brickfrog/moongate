// Node host services for the `--target js` bundle used by the GitHub Action.
//
// Every bridge returns a JSON string: binary payloads travel base64-encoded,
// so no byte buffer has to cross the FFI boundary.

///|
extern "js" fn spawn_bridge(
  program : String,
  args : String,
  env : String,
  timeout_ms : Int,
  max_output_bytes : Int,
) -> @js_async.Promise[String] =
  #| (program, args, env, timeoutMs, maxOutputBytes) => (async () => {
  #|   const { execFile } = require("node:child_process");
  #|   return await new Promise((resolve) => {
  #|     execFile(
  #|       program,
  #|       JSON.parse(args),
  #|       {
  #|         env: JSON.parse(env),
  #|         encoding: "buffer",
  #|         timeout: timeoutMs,
  #|         maxBuffer: maxOutputBytes,
  #|         windowsHide: true,
  #|       },
  #|       (err, stdout, stderr) => {
  #|         // execFile signals a timeout with a signal and an overflow with a
  #|         // string code; neither is an exit status, and reporting them as
  #|         // "exited 1" would hand truncated evidence to the caller.
  #|         if (err && (err.killed || err.signal)) {
  #|           resolve(JSON.stringify({ error: "Running '" + program + "' timed out." }));
  #|           return;
  #|         }
  #|         if (err && typeof err.code !== "number") {
  #|           resolve(JSON.stringify({ error: "Running '" + program + "' failed: " + String(err.code || err.message || err) }));
  #|           return;
  #|         }
  #|         resolve(JSON.stringify({
  #|           code: err ? (typeof err.code === "number" ? err.code : 1) : 0,
  #|           stdout: Buffer.from(stdout).toString("base64"),
  #|           stderr: Buffer.from(stderr).toString("utf8"),
  #|         }));
  #|       },
  #|     );
  #|   });
  #| })()

///|
extern "js" fn fetch_bridge(
  url : String,
  headers : String,
  body : String,
  timeout_ms : Int,
  max_response_bytes : Int,
) -> @js_async.Promise[String] =
  #| (url, headers, body, timeoutMs, maxResponseBytes) => (async () => {
  #|   const controller = new AbortController();
  #|   const timer = setTimeout(() => controller.abort(), timeoutMs);
  #|   try {
  #|     const res = await fetch(url, {
  #|       method: "POST",
  #|       headers: JSON.parse(headers),
  #|       body,
  #|       redirect: "manual",
  #|       signal: controller.signal,
  #|     });
  #|     // Capped while reading, like the native path: a hostile or broken
  #|     // endpoint must not be able to buffer an unbounded body first.
  #|     const parts = [];
  #|     let total = 0;
  #|     if (res.body) {
  #|       for await (const chunk of res.body) {
  #|         total += chunk.length;
  #|         if (total > maxResponseBytes) {
  #|           controller.abort();
  #|           return JSON.stringify({ error: "Evaluation response exceeds its size limit." });
  #|         }
  #|         parts.push(chunk);
  #|       }
  #|     }
  #|     const buf = Buffer.concat(parts);
  #|     return JSON.stringify({
  #|       status: res.status,
  #|       requestId: res.headers.get("x-typesafe-request-id") || "",
  #|       body: buf.toString("base64"),
  #|     });
  #|   } catch (err) {
  #|     return JSON.stringify({ error: String((err && err.message) || err) });
  #|   } finally {
  #|     clearTimeout(timer);
  #|   }
  #| })()

///|
extern "js" fn stat_bridge(path : String) -> @js_async.Promise[String] =
  #| (path) => (async () => {
  #|   const fs = require("node:fs/promises");
  #|   try {
  #|     const info = await fs.lstat(path);
  #|     return JSON.stringify({ kind: info.isFile() ? "regular" : "other", size: info.size });
  #|   } catch {
  #|     return JSON.stringify({ kind: "missing", size: 0 });
  #|   }
  #| })()

///|
extern "js" fn read_file_bridge(path : String) -> @js_async.Promise[String] =
  #| (path) => (async () => {
  #|   const fs = require("node:fs/promises");
  #|   try {
  #|     const data = await fs.readFile(path);
  #|     return JSON.stringify({ data: data.toString("base64") });
  #|   } catch (err) {
  #|     return JSON.stringify({ error: String((err && err.message) || err) });
  #|   }
  #| })()

///|
extern "js" fn realpath_bridge(path : String) -> @js_async.Promise[String] =
  #| (path) => (async () => {
  #|   const fs = require("node:fs/promises");
  #|   try {
  #|     return await fs.realpath(path);
  #|   } catch {
  #|     return path;
  #|   }
  #| })()

///|
extern "js" fn cwd_bridge() -> String =
  #| () => process.cwd()

///|
extern "js" fn env_bridge() -> String =
  #| () => JSON.stringify(process.env)

///|
extern "js" fn argv_bridge() -> String =
  #| () => JSON.stringify(process.argv.slice(1))

///|
extern "js" fn write_bridge(stream : Int, text : String) -> Unit =
  #| (stream, text) => {
  #|   if (stream === 1) { process.stdout.write(text); } else { process.stderr.write(text); }
  #| }

///|
/// Sets the status without calling `process.exit`, which discards whatever is
/// still queued on a piped stdout. Node exits with this code once the write
/// queue drains.
extern "js" fn exit_bridge(code : Int) -> Unit =
  #| (code) => { process.exitCode = code; }

///|
fn decode_bridge(text : String) -> Json raise {
  let value = try @json.parse(text) catch {
    _ => raise @host.HostError("A host bridge returned malformed JSON.")
  }
  match value {
    Object(fields) =>
      match fields.get("error") {
        Some(String(message)) => raise @host.HostError(message)
        _ => value
      }
    _ => raise @host.HostError("A host bridge returned an unexpected shape.")
  }
}

///|
fn string_field(value : Json, name : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
fn int_field(value : Json, name : String) -> Int {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(Number(number, ..)) => number.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
async fn run_command(
  program : String,
  args : Array[String],
  env : Map[String, String],
  timeout_ms~ : Int,
  max_output_bytes~ : Int,
) -> @host.CommandResult raise {
  let arg_json = Json::array(args.map(fn(arg) { Json::string(arg) })).stringify()
  let env_table : Map[String, Json] = Map([])
  for name, value in env {
    env_table[name] = Json::string(value)
  }
  let result = decode_bridge(
    spawn_bridge(
      program,
      arg_json,
      Json::object(env_table).stringify(),
      timeout_ms,
      max_output_bytes,
    ).wait(),
  )
  {
    code: int_field(result, "code"),
    stdout: @host.decode_base64(string_field(result, "stdout")),
    stderr: string_field(result, "stderr"),
  }
}

///|
async fn post_json(
  origin : String,
  path : String,
  headers : Array[(String, String)],
  body : String,
  timeout_ms~ : Int,
  max_response_bytes~ : Int,
) -> @host.HttpResponse raise {
  let table : Map[String, Json] = Map([])
  for header in headers {
    table[header.0] = Json::string(header.1)
  }
  let result = decode_bridge(
    fetch_bridge(
      origin + path,
      Json::object(table).stringify(),
      body,
      timeout_ms,
      max_response_bytes,
    ).wait(),
  )
  {
    status: int_field(result, "status"),
    request_id: string_field(result, "requestId"),
    body: @host.decode_base64(string_field(result, "body")),
  }
}

///|
async fn path_kind(path : String) -> @host.PathKind raise {
  match string_field(decode_bridge(stat_bridge(path).wait()), "kind") {
    "regular" => @host.Regular
    "missing" => @host.Missing
    _ => Other
  }
}

///|
async fn file_size(path : String) -> Int64 raise {
  int_field(decode_bridge(stat_bridge(path).wait()), "size").to_int64()
}

///|
async fn read_file(path : String) -> Bytes raise {
  @host.decode_base64(string_field(decode_bridge(read_file_bridge(path).wait()), "data"))
}

///|
async fn realpath(path : String) -> String raise {
  realpath_bridge(path).wait()
}

///|
fn current_dir() -> String? {
  Some(cwd_bridge())
}

///|
fn env_vars() -> Map[String, String] {
  let out : Map[String, String] = Map([])
  let parsed = @json.parse(env_bridge()) catch {
    _ => Json::object(Map([]))
  }
  match parsed {
    Object(fields) =>
      for name, value in fields {
        match value {
          String(text) => out[name] = text
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn args() -> Array[String] {
  let out = []
  let parsed = @json.parse(argv_bridge()) catch {
    _ => Json::array([])
  }
  match parsed {
    Array(items) =>
      for item in items {
        match item {
          String(text) => out.push(text)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn write_stdout(text : String) -> Unit {
  write_bridge(1, text)
}

///|
fn write_stderr(text : String) -> Unit {
  write_bridge(2, text)
}

///|
fn exit(code : Int) -> Unit {
  exit_bridge(code)
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

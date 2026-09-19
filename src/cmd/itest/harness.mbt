// Consumer-visible integration tests for the Moongate CLI.
//
// Every scenario drives the real binary against a real temporary Git
// repository. A loopback HTTP fixture stands in for the TypeSafe API, so the
// suite needs no credential and makes no external request.
//
// This package deliberately does not import `brickfrog/moongate/core`. The
// tests assert what a consumer sees — exit code and process output — so they
// must not be able to reuse the implementation's own idea of correctness.

///|
/// Credential supplied to the binary. It must never appear in any output.
let dummy_key : String = "test-key-do-not-log"

///|
let failures : Array[String] = []

///|
let passed : Ref[Int] = { val: 0 }

///|
/// Records one assertion.
fn check(name : String, condition : Bool, detail : String) -> Unit {
  if condition {
    passed.val += 1
  } else {
    failures.push("\{name}: \{detail}")
  }
}

///|
suberror ItestError {
  ItestError(String)
}

///|
fn[X] fail(message : String) -> X raise {
  raise ItestError(message)
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

///|
struct Recorded {
  path : String
  auth : String
  body : Json
}

///|
struct Queued {
  status : Int
  body : String
  headers : Array[(String, String)]
}

///|
/// Local stand-in for the evaluation API.
struct Fixture {
  requests : Array[Recorded]
  responses : Array[Queued]
  mut origin : String
}

///|
fn Fixture::new() -> Fixture {
  { requests: [], responses: [], origin: "" }
}

///|
/// Queues one response. Requests beyond the queue receive a 500.
fn Fixture::queue(
  self : Fixture,
  body : String,
  status~ : Int = 200,
  headers~ : Array[(String, String)] = [],
) -> Unit {
  self.responses.push({ status, body, headers })
}

///|
fn Fixture::queue_json(
  self : Fixture,
  body : Json,
  status~ : Int = 200,
  headers~ : Array[(String, String)] = [],
) -> Unit {
  self.queue(body.stringify(), status~, headers~)
}

///|
/// Last recorded request. Raises when no request was made.
fn Fixture::last(self : Fixture) -> Recorded raise {
  if self.requests.is_empty() {
    fail("no request was recorded")
  }
  self.requests[self.requests.length() - 1]
}

///|
/// Parses a decimal byte count. Any other spelling means no body.
fn parse_digits(text : String) -> Int {
  let mut total = 0
  for ch in text {
    if ch < '0' || ch > '9' {
      return 0
    }
    total = total * 10 + (ch.to_int() - '0'.to_int())
    if total > 64 * 1024 * 1024 {
      return 0
    }
  }
  total
}

///|
fn reason_phrase(status : Int) -> String {
  match status {
    200 => "OK"
    302 => "Found"
    429 => "Too Many Requests"
    500 => "Internal Server Error"
    _ => "Status"
  }
}

///|
/// Serves one connection: read the request, record it, send the queued reply.
async fn Fixture::serve_one(self : Fixture, conn : @socket.Tcp) -> Unit {
  let head = match conn.read_until("\r\n\r\n") {
    Some(text) => text
    None => return
  }
  let lines = []
  for line in head.split("\r\n") {
    lines.push(line.to_owned())
  }
  let request_line = if lines.is_empty() { "" } else { lines[0] }
  let parts = []
  for part in request_line.split(" ") {
    parts.push(part.to_owned())
  }
  let path = if parts.length() > 1 { parts[1] } else { "" }
  let mut length = 0
  let mut auth = ""
  for i in 1..<lines.length() {
    // Header values here never contain a colon-free ambiguity worth more
    // parsing than this: the fixture only reads two known headers.
    let pieces = []
    for piece in lines[i].split(":") {
      pieces.push(piece.to_owned())
    }
    if pieces.length() < 2 {
      continue
    }
    let name = pieces[0].to_lower()
    let value = pieces[1:]
      .iter()
      .fold(init="", fn(acc, piece) {
        if acc.is_empty() { piece } else { acc + ":" + piece }
      })
      .trim(chars=" \t")
      .to_owned()
    if name == "content-length" {
      length = parse_digits(value)
    } else if name == "authorization" {
      auth = value
    }
  }
  let raw = if length > 0 { conn.read_exactly(length) } else { b"" }
  let text = @utf8.decode(raw[:]) catch {
    _ => ""
  }
  let body = @json.parse(text) catch {
    _ => Json::string(text)
  }
  self.requests.push({ path, auth, body })
  let reply = if self.responses.is_empty() {
    { status: 500, body: "{\"error\":\"no fixture queued\"}", headers: [] }
  } else {
    self.responses.remove(0)
  }
  let payload = @utf8.encode(reply.body)
  let out = StringBuilder()
  out.write_string(
    "HTTP/1.1 \{reply.status} \{reason_phrase(reply.status)}\r\n",
  )
  out.write_string("content-type: application/json\r\n")
  out.write_string("content-length: \{payload.length()}\r\n")
  out.write_string("connection: close\r\n")
  for header in reply.headers {
    out.write_string("\{header.0}: \{header.1}\r\n")
  }
  out.write_string("\r\n")
  conn.write(out.to_string())
  if payload.length() > 0 {
    conn.write(payload)
  }
}

///|
/// Binds loopback on an ephemeral port and serves until the group ends.
async fn Fixture::start(self : Fixture, group : @async.TaskGroup[Unit]) -> Unit {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    reuse_addr=true,
  )
  self.origin = "http://127.0.0.1:\{server.addr.port()}"
  group.add_defer(() => server.close())
  group.spawn_bg(no_wait=true, allow_failure=true, () => server.run_forever(
    allow_failure=true,
    (conn, _) => {
      defer conn.close()
      self.serve_one(conn)
    },
  ))
}

// ---------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------

///|
struct Proc {
  code : Int
  stdout : String
  stderr : String
}

///|
/// Environment for child processes. Built explicitly rather than inherited, so
/// an ambient TYPESAFE_API_KEY on the developer's machine cannot reach a child.
fn base_env() -> Map[String, String] {
  let env = @env.get_env_vars()
  let out : Map[String, String] = Map([])
  for name in ["PATH", "HOME", "LANG", "TMPDIR", "SYSTEMROOT"] {
    match env.get(name) {
      Some(value) => out[name] = value
      None => ()
    }
  }
  out
}

///|
async fn run_process(
  program : String,
  args : Array[String],
  cwd : String,
  env : Map[String, String],
) -> Proc raise {
  let output = @shell.Cmd(
    program,
    args,
    cwd~,
    env~,
    inherit_env=false,
    stdout=Capture,
    stderr=Capture,
  ).output(timeout_ms=120000, max_output_bytes=8 * 1024 * 1024)
  { code: output.exit_code(), stdout: output.stdout(), stderr: output.stderr() }
}

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

///|
struct Repo {
  path : String
}

///|
/// Directories to remove when the suite finishes.
let temp_dirs : Array[String] = []

///|
async fn new_repo() -> Repo raise {
  let path = @fs.tmpdir(prefix="moongate-it-")
  temp_dirs.push(path)
  let repo = Repo::{ path, }
  repo.git(["init", "-q", "-b", "main"]) |> ignore
  repo
}

///|
async fn Repo::git(self : Repo, args : Array[String]) -> String raise {
  let env = base_env()
  env["GIT_AUTHOR_NAME"] = "Test"
  env["GIT_AUTHOR_EMAIL"] = "test@example.com"
  env["GIT_COMMITTER_NAME"] = "Test"
  env["GIT_COMMITTER_EMAIL"] = "test@example.com"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["GIT_CONFIG_SYSTEM"] = "/dev/null"
  let result = run_process("git", args, self.path, env)
  if result.code != 0 {
    fail("git \{args.join(" ")} failed: \{result.stderr}")
  }
  result.stdout
}

///|
fn dirname(path : String) -> String {
  match path.rev_find("/") {
    Some(at) => path[:at].to_owned()
    None => ""
  }
}

///|
async fn Repo::write(self : Repo, rel : String, content : String) -> Unit raise {
  self.write_bytes(rel, @utf8.encode(content))
}

///|
async fn Repo::write_bytes(
  self : Repo,
  rel : String,
  content : Bytes,
) -> Unit raise {
  let full = "\{self.path}/\{rel}"
  let parent = dirname(full)
  if parent != "" {
    @fs.mkdir(parent, recursive=true) catch {
      _ => ()
    }
  }
  @fs.write_file(full, content)
}

///|
async fn Repo::remove(self : Repo, rel : String) -> Unit raise {
  @fs.remove("\{self.path}/\{rel}")
}

///|
async fn Repo::symlink(self : Repo, target : String, rel : String) -> Unit raise {
  @fs.symlink(target~, "\{self.path}/\{rel}")
}

///|
async fn Repo::commit(self : Repo, message : String) -> String raise {
  self.git(["add", "-A"]) |> ignore
  self.git(["commit", "-q", "-m", message]) |> ignore
  self.git(["rev-parse", "HEAD"]).trim(chars="\n").to_owned()
}

// ---------------------------------------------------------------------------
// Invoking the binary
// ---------------------------------------------------------------------------

///|
/// Path of the binary under test, set once from the command line.
let binary : Ref[String] = { val: "" }

///|
/// Runs the CLI. `key` defaults to the dummy credential; `None` omits it.
async fn run_cli(
  repo : Repo,
  args : Array[String],
  base_url~ : String? = None,
  key~ : String? = Some(dummy_key),
) -> Proc raise {
  let env = base_env()
  match key {
    Some(value) => env["TYPESAFE_API_KEY"] = value
    None => ()
  }
  match base_url {
    Some(value) => env["TYPESAFE_BASE_URL"] = value
    None => ()
  }
  run_process(binary.val, args, repo.path, env)
}

///|
fn expect_exit(name : String, proc : Proc, code : Int) -> Unit {
  check(
    name,
    proc.code == code,
    "expected exit \{code}, got \{proc.code}\nstdout=\{clip(proc.stdout)}\nstderr=\{clip(proc.stderr)}",
  )
}

///|
fn clip(text : String) -> String {
  if text.length() > 2000 {
    text[:2000].to_owned()
  } else {
    text
  }
}

///|
/// Parses the report on stdout. Raises when stdout is not JSON, which is
/// itself a failure worth surfacing.
fn report(proc : Proc) -> Json raise {
  @json.parse(proc.stdout) catch {
    _ => fail("stdout is not JSON: \{clip(proc.stdout)}")
  }
}

///|
fn field(doc : Json, name : String) -> Json {
  match doc {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn text_of(value : Json) -> String {
  match value {
    String(text) => text
    _ => value.stringify()
  }
}

///|
/// Renders a value for a failure message without a Show instance.
fn describe(items : Array[Json]) -> String {
  items.map(fn(item) { item.stringify() }).join(", ")
}

///|
fn array_of(value : Json) -> Array[Json] {
  match value {
    Array(items) => items
    _ => []
  }
}

///|
fn conclusion(doc : Json) -> String {
  text_of(field(doc, "conclusion"))
}

///|
fn status_of(doc : Json, rule_id : String) -> String {
  for result in array_of(field(doc, "results")) {
    if text_of(field(result, "id")) == rule_id {
      return text_of(field(result, "status"))
    }
  }
  "<missing>"
}

///|
/// Sorted `new_path` values of the changes in the last recorded request.
fn sent_paths(state : Json) -> Array[String] {
  let paths = []
  for change in array_of(field(state, "changes")) {
    match field(change, "new_path") {
      String(path) => paths.push(path)
      _ => ()
    }
  }
  paths.sort()
  paths
}

// ---------------------------------------------------------------------------
// Configuration builders
// ---------------------------------------------------------------------------

///|
/// The default rule. Overrides replace whole top-level members.
fn rule(overrides : Array[(String, Json)]) -> Json {
  let fields : Map[String, Json] = Map([
    ("id", Json::string("no_secret_logging")),
    ("source", Json::string("AGENTS.md:1")),
    ("severity", Json::string("advisory")),
    ("globs", [Json::string("src/**/*.py")]),
    (
      "thresholds",
      Json::object(
        Map([("min_probability", 0.9), ("min_confidence", 0.8)].map(fn(pair) {
          (pair.0, Json::number(pair.1))
        })),
      ),
    ),
    (
      "question",
      Json::object(
        Map([
          ("type", Json::string("choice")),
          ("instructions", Json::string("Does the change log credentials?")),
          (
            "criteria",
            Json::object(
              Map([
                ("violation", Json::string("Credentials are written to a log.")),
                ("compliant", Json::string("No credentials are logged.")),
                ("insufficient_evidence", Json::string("Not enough context.")),
              ]),
            ),
          ),
        ]),
      ),
    ),
    ("message", Json::string("Do not log credentials.")),
  ])
  for pair in overrides {
    if pair.1 is Null {
      fields.remove(pair.0)
    } else {
      fields[pair.0] = pair.1
    }
  }
  Json::object(fields)
}

///|
fn strings(values : Array[String]) -> Json {
  Json::array(values.map(fn(value) { Json::string(value) }))
}

///|
fn thresholds(probability : Double, confidence : Double) -> Json {
  Json::object(
    Map([
      ("min_probability", Json::number(probability)),
      ("min_confidence", Json::number(confidence)),
    ]),
  )
}

///|
fn config(rules : Array[Json]) -> String {
  Json::object(
    Map([
      ("version", Json::number(1)),
      ("model", Json::string("jev-1.13.0")),
      ("rules", Json::array(rules)),
    ]),
  ).stringify() +
  "\n"
}

// ---------------------------------------------------------------------------
// Response builders
// ---------------------------------------------------------------------------

///|
fn answer(choice : String, probs : Array[(String, Double)], confidence : Double) -> Json {
  Json::object(
    Map([
      ("type", Json::string("choice")),
      ("choice", Json::string(choice)),
      (
        "probabilities",
        Json::object(
          Map(probs.map(fn(pair) { (pair.0, Json::number(pair.1)) })),
        ),
      ),
      ("confidence", Json::number(confidence)),
    ]),
  )
}

///|
fn decisive(choice : String) -> Json {
  let probs = [
    ("violation", 0.01),
    ("compliant", 0.01),
    ("insufficient_evidence", 0.01),
  ].map(fn(pair) { if pair.0 == choice { (pair.0, 0.98) } else { pair } })
  answer(choice, probs, 0.95)
}

///|
fn response(answers : Array[(String, Json)], model~ : String = "jev-1.13.0") -> Json {
  Json::object(
    Map([
      ("model", Json::string(model)),
      ("answers", Json::object(Map(answers))),
      ("usage", Json::object(Map([("input_tokens", Json::number(10))]))),
    ]),
  )
}

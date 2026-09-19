///|
/// Hard ceiling for any captured Git output or single blob.
pub let max_blob_bytes : Int = 8 * 1024 * 1024

///|
/// Hard ceiling for the number of change records considered.
pub let max_change_records : Int = 10000

///|
let git_timeout_ms : Int = 30000

///|
/// One record from `git diff --raw`.
pub(all) struct ChangeRecord {
  status : String
  old_mode : String
  new_mode : String
  old_oid : String
  new_oid : String
  old_path : String?
  new_path : String?
}

///|
pub fn ChangeRecord::key(self : ChangeRecord) -> String {
  match self.new_path {
    Some(path) => path
    None =>
      match self.old_path {
        Some(path) => path
        None => ""
      }
  }
}

///|
/// Builds the child environment for every Git invocation.
///
/// The API key is removed so no child process can observe it, and all
/// configuration injection points are neutralised so repository or user
/// configuration cannot introduce an external diff driver, a textconv filter,
/// or a credential prompt.
fn git_env() -> Map[String, String] raise {
  let env = (@host.current().env_vars)()
  let clean : Map[String, String] = Map([])
  for key, value in env {
    // An Actions runtime exports every input as INPUT_*, including the API
    // key, so the whole prefix is dropped rather than one known name.
    if key == "TYPESAFE_API_KEY" ||
      key.has_prefix("INPUT_") ||
      key == "GIT_CONFIG_PARAMETERS" ||
      key == "GIT_CONFIG_COUNT" ||
      key.has_prefix("GIT_CONFIG_KEY_") ||
      key.has_prefix("GIT_CONFIG_VALUE_") {
      continue
    }
    clean[key] = value
  }
  clean["GIT_TERMINAL_PROMPT"] = "0"
  clean["GIT_PAGER"] = "cat"
  clean["GIT_NO_REPLACE_OBJECTS"] = "1"
  // Configured paths are exact filenames, never pathspecs: without this, '*',
  // '?' or a leading ':' in a path would silently resolve to other files.
  clean["GIT_LITERAL_PATHSPECS"] = "1"
  clean["GIT_CONFIG_GLOBAL"] = "/dev/null"
  clean["GIT_CONFIG_SYSTEM"] = "/dev/null"
  clean
}

///|
/// Runs Git with a literal argument vector and returns raw stdout bytes.
async fn git_bytes(args : Array[String]) -> Bytes raise {
  let result = try (@host.current().run_command)(
      "git",
      args,
      git_env(),
      git_timeout_ms,
      max_blob_bytes,
    ) catch {
    err => raise @core.GateError("git \{args[0]} failed: \{describe(err)}")
  }
  if result.code != 0 {
    raise @core.GateError("git \{args[0]} exited with status \{result.code}.")
  }
  result.stdout
}

///|
/// Reduces a foreign error to a safe short description.
fn describe(err : Error) -> String {
  @core.sanitize_line(err.to_string())
}

///|
async fn git_line(args : Array[String]) -> String raise {
  let text = decode_utf8(git_bytes(args), "git output")
  text.trim(chars=" \t\r\n").to_owned()
}

///|
fn decode_utf8(data : Bytes, what : String) -> String raise {
  try @utf8.decode(data[:]) catch {
    _ => raise @core.GateError("\{what} is not valid UTF-8.")
  }
}

///|
/// Confirms the process runs at the repository root, as every configured path
/// is root-relative.
pub async fn assert_repo_root() -> Unit raise {
  let top = git_line(["rev-parse", "--show-toplevel"])
  let here = match (@host.current().current_dir)() {
    Some(dir) => (@host.current().realpath)(dir)
    None => raise @core.GateError("Cannot determine the current directory.")
  }
  let top_real = (@host.current().realpath)(top)
  if top_real != here {
    raise @core.GateError(
      "Moongate must run from the repository root (\{@core.sanitize_line(top_real)}).",
    )
  }
}

///|
/// Resolves a ref to a commit object id.
pub async fn resolve_commit(ref_name : String, what : String) -> String raise {
  let oid = try git_line([
      "rev-parse", "--verify", "--end-of-options", ref_name + "^{commit}",
    ]) catch {
    _ =>
      raise @core.GateError(
        "Cannot resolve \{what} '\{@core.sanitize_line(ref_name)}' to a commit. Fetch more history.",
      )
  }
  if oid.length() != 40 {
    raise @core.GateError(
      "Unexpected object id for \{what} '\{@core.sanitize_line(ref_name)}'.",
    )
  }
  oid
}

///|
/// Returns the single merge base of base and head.
pub async fn merge_base(base : String, head : String) -> String raise {
  let text = decode_utf8(
    git_bytes(["merge-base", "--all", base, head]),
    "git merge-base output",
  )
  let bases : Array[String] = []
  for line in text.split("\n") {
    let line = line.trim(chars=" \t\r").to_owned()
    if !line.is_empty() {
      bases.push(line)
    }
  }
  if bases.is_empty() {
    raise @core.GateError(
      "No merge base between base and head. Fetch the full history of both commits.",
    )
  }
  if bases.length() > 1 {
    raise @core.GateError(
      "Ambiguous history: \{bases.length()} merge bases between base and head.",
    )
  }
  bases[0]
}

///|
/// Splits NUL-delimited bytes into fields.
fn split_nul(data : Bytes) -> Array[Bytes] raise {
  let out : Array[Bytes] = []
  let mut start = 0
  for i = 0; i < data.length(); i = i + 1 {
    if data[i] == b'\x00' {
      out.push(data[start:i].to_owned())
      start = i + 1
    }
  }
  if start != data.length() {
    raise @core.GateError("Malformed NUL-delimited git output.")
  }
  out
}

///|
/// Reads the raw change manifest between two commits.
pub async fn raw_changes(from : String, to : String) -> Array[ChangeRecord] raise {
  let data = git_bytes([
    "--no-pager", "diff", "--raw", "-z", "--no-abbrev", "--find-renames=50%",
    "--no-ext-diff", "--no-textconv", from, to, "--",
  ])
  let fields = split_nul(data)
  let records : Array[ChangeRecord] = []
  let mut i = 0
  while i < fields.length() {
    let header = decode_utf8(fields[i], "git diff record")
    if !header.has_prefix(":") {
      raise @core.GateError("Unexpected git diff record.")
    }
    let parts : Array[String] = []
    for part in header.split(" ") {
      if !part.is_empty() {
        parts.push(part.to_owned())
      }
    }
    if parts.length() != 5 {
      raise @core.GateError("Unexpected git diff record field count.")
    }
    let old_mode = match parts[0].strip_prefix(":") {
      Some(view) => view.to_owned()
      None => raise @core.GateError("Unexpected git diff record header.")
    }
    let new_mode = parts[1]
    let old_oid = parts[2]
    let new_oid = parts[3]
    let status_field = parts[4]
    let status = status_field.get_char(0).unwrap().to_string()
    let two_paths = status == "R" || status == "C"
    let needed = if two_paths { 2 } else { 1 }
    if i + needed >= fields.length() {
      raise @core.GateError("Truncated git diff record.")
    }
    let first = decode_utf8(fields[i + 1], "git diff path")
    @core.validate_rel_path(first, "changed")
    let record = if two_paths {
      let second = decode_utf8(fields[i + 2], "git diff path")
      @core.validate_rel_path(second, "changed")
      {
        status,
        old_mode,
        new_mode,
        old_oid,
        new_oid,
        old_path: Some(first),
        new_path: Some(second),
      }
    } else if status == "A" {
      { status, old_mode, new_mode, old_oid, new_oid, old_path: None, new_path: Some(first) }
    } else if status == "D" {
      { status, old_mode, new_mode, old_oid, new_oid, old_path: Some(first), new_path: None }
    } else if status == "M" || status == "T" {
      {
        status,
        old_mode,
        new_mode,
        old_oid,
        new_oid,
        old_path: Some(first),
        new_path: Some(first),
      }
    } else {
      raise @core.GateError(
        "Unsupported git change status '\{@core.sanitize_line(status_field)}'.",
      )
    }
    records.push(record)
    i = i + 1 + needed
    if records.length() > max_change_records {
      raise @core.GateError(
        "Change set exceeds \{max_change_records} records; narrow the rule globs.",
      )
    }
  }
  records.sort_by_key(fn(r) { r.key() })
  records
}

///|
let null_oid : String = "0000000000000000000000000000000000000000"

///|
fn is_regular(mode : String) -> Bool {
  mode == "100644" || mode == "100755"
}

///|
/// Returns the byte size of a blob.
async fn blob_size(oid : String) -> Int raise {
  let text = git_line(["cat-file", "-s", oid])
  let mut size = 0
  if text.is_empty() {
    raise @core.GateError("Cannot read object size for \{oid}.")
  }
  for ch in text {
    if ch < '0' || ch > '9' {
      raise @core.GateError("Cannot read object size for \{oid}.")
    }
    size = size * 10 + (ch.to_int() - '0'.to_int())
    if size > max_blob_bytes {
      return size
    }
  }
  size
}

///|
/// Reads a blob as validated UTF-8 text.
async fn blob_text(oid : String, path : String) -> String raise {
  let size = blob_size(oid)
  if size > max_blob_bytes {
    raise @core.GateError(
      "File '\{@core.sanitize_line(path)}' exceeds the \{max_blob_bytes} byte evidence limit.",
    )
  }
  let data = git_bytes(["cat-file", "blob", oid])
  for i = 0; i < data.length(); i = i + 1 {
    if data[i] == b'\x00' {
      raise @core.GateError(
        "File '\{@core.sanitize_line(path)}' is binary; exclude it from the rule globs.",
      )
    }
  }
  try @utf8.decode(data[:]) catch {
    _ =>
      raise @core.GateError(
        "File '\{@core.sanitize_line(path)}' is not valid UTF-8; exclude it from the rule globs.",
      )
  }
}

///|
/// Reads a regular-file blob id at a commit, or `None` when absent.
pub async fn tree_blob(commit : String, path : String) -> String? raise {
  let data = git_bytes(["ls-tree", "-z", "--full-name", commit, "--", path])
  let entries = if data.length() == 0 { [] } else { split_nul(data) }
  if entries.is_empty() {
    return None
  }
  if entries.length() > 1 {
    raise @core.GateError(
      "Path '\{@core.sanitize_line(path)}' resolves to \{entries.length()} tree entries; it must name one file.",
    )
  }
  let line = decode_utf8(entries[0], "git ls-tree output")
  let (meta, _) = match line.split_once("\t") {
    Some(pair) => pair
    None => raise @core.GateError("Unexpected git ls-tree output.")
  }
  let parts : Array[String] = []
  for part in meta.split(" ") {
    if !part.is_empty() {
      parts.push(part.to_owned())
    }
  }
  if parts.length() != 3 {
    raise @core.GateError("Unexpected git ls-tree metadata.")
  }
  let mode = parts[0]
  let kind = parts[1]
  if kind != "blob" || !is_regular(mode) {
    raise @core.GateError(
      "Context path '\{@core.sanitize_line(path)}' is not a regular file.",
    )
  }
  Some(parts[2])
}

///|
/// Reads a config blob out of a commit, rejecting anything but a regular file.
pub async fn config_from_commit(commit : String, path : String) -> String raise {
  @core.validate_rel_path(path, "configuration")
  match tree_blob(commit, path) {
    None =>
      raise @core.GateError(
        "Configuration '\{@core.sanitize_line(path)}' does not exist at the config ref.",
      )
    Some(oid) => {
      let size = blob_size(oid)
      if size > @core.max_config_bytes {
        raise @core.GateError("Configuration exceeds the 1 MiB limit.")
      }
      let data = git_bytes(["cat-file", "blob", oid])
      decode_utf8(data, "configuration")
    }
  }
}

///|
/// Reads the context text of a path at one commit, or `None` when absent.
pub async fn context_text(commit : String, path : String) -> String? raise {
  match tree_blob(commit, path) {
    None => None
    Some(oid) => Some(blob_text(oid, path))
  }
}

///|
/// Produces the evidence patch for one change record.
///
/// Patches always come from the exact recorded blob ids, never from a tree
/// diff restricted by path: a path filter can pick up descendants when a file
/// is replaced by a directory, which would leak excluded files.
pub async fn record_patch(record : ChangeRecord) -> String raise {
  let path = @core.sanitize_line(record.key())
  let old_present = record.old_oid != null_oid
  let new_present = record.new_oid != null_oid
  if old_present && !is_regular(record.old_mode) {
    raise @core.GateError(
      "Path '\{path}' is not a regular file at the base revision (mode \{record.old_mode}); exclude it.",
    )
  }
  if new_present && !is_regular(record.new_mode) {
    raise @core.GateError(
      "Path '\{path}' is not a regular file at the head revision (mode \{record.new_mode}); exclude it.",
    )
  }
  if old_present && new_present && record.old_oid == record.new_oid {
    // Pure rename or mode change: metadata alone is the evidence.
    return ""
  }
  if old_present && new_present {
    // Validate both sides as text before asking Git to diff them.
    blob_text(record.old_oid, record.key()) |> ignore
    blob_text(record.new_oid, record.key()) |> ignore
    let data = git_bytes([
      "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
      "--text", "--unified=20", record.old_oid, record.new_oid,
    ])
    let text = decode_utf8(data, "git diff output")
    if text.is_empty() {
      raise @core.GateError(
        "Path '\{path}' changed content but produced no diff evidence.",
      )
    }
    return text
  }
  if new_present {
    let text = blob_text(record.new_oid, record.key())
    return whole_file_hunk(text, true)
  }
  let text = blob_text(record.old_oid, record.key())
  whole_file_hunk(text, false)
}

///|
/// Renders an all-added or all-removed hunk for a file that exists on one
/// side only. Paths live in the record metadata, so the headers are generic.
fn whole_file_hunk(text : String, added : Bool) -> String {
  if text.is_empty() {
    return ""
  }
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.to_owned())
  }
  let mut trailing_newline = false
  if lines.length() > 0 && lines[lines.length() - 1].is_empty() {
    lines.pop() |> ignore
    trailing_newline = true
  }
  let out = StringBuilder()
  out.write_string("--- before\n+++ after\n")
  let count = lines.length()
  if added {
    out.write_string("@@ -0,0 +1,\{count} @@\n")
  } else {
    out.write_string("@@ -1,\{count} +0,0 @@\n")
  }
  let marker = if added { "+" } else { "-" }
  for line in lines {
    out.write_string("\{marker}\{line}\n")
  }
  if !trailing_newline {
    out.write_string("\\ No newline at end of file\n")
  }
  out.to_string()
}

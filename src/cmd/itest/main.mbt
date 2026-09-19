///|
/// Entry point: `moon run src/cmd/itest -- --bin PATH`.
async fn main {
  let argv = @env.args()
  let mut path = ""
  for i in 1..<argv.length() {
    if argv[i] == "--bin" && i + 1 < argv.length() {
      path = argv[i + 1]
    }
  }
  if path.is_empty() {
    @stdio.stderr.write("usage: itest --bin PATH\n")
    @sys.exit(2)
    return
  }
  binary.val = path
  if !(@fs.exists(path)) {
    @stdio.stderr.write("binary not found: \{path}\n")
    @sys.exit(2)
    return
  }
  let fixture = Fixture::new()
  @async.with_task_group(group => {
    fixture.start(group)
    group.add_defer(() => cleanup())
    run_scenarios(fixture)
    group.return_immediately(()) catch {
      _ => ()
    }
  })
  @stdio.stdout.write("passed \{passed.val} checks\n")
  for failure in failures {
    @stdio.stdout.write("FAIL \{failure}\n")
  }
  @sys.exit(if failures.is_empty() { 0 } else { 1 })
}

///|
async fn cleanup() -> Unit {
  for path in temp_dirs {
    @fs.rmdir(path, recursive=true) catch {
      _ => ()
    }
  }
}

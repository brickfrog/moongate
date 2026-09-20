///|
let version : String = "0.1.0"

///|
fn build_command() -> @argparse.Command {
  let validate = @argparse.Command(
    "validate",
    about="Validate a Moongate configuration file",
    options=[
      @argparse.OptionArg(
        "config",
        long="config",
        about="Configuration path (default .moongate.json)",
      ),
      @argparse.OptionArg(
        "format",
        long="format",
        about="Output format: text, json or github",
      ),
    ],
  )
  let check = @argparse.Command(
    "check",
    about="Evaluate committed changes against the configured rules",
    flags=[
      @argparse.FlagArg(
        "report-json",
        long="report-json",
        about="Also write the JSON report to stderr, framed by \"--- moongate report begin ---\" and \"--- moongate report end ---\" lines because that stream also carries diagnostics",
      ),
    ],
    options=[
      @argparse.OptionArg(
        "base",
        long="base",
        about="Base ref or commit (required)",
        required=true,
      ),
      @argparse.OptionArg("head", long="head", about="Head ref or commit (default HEAD)"),
      @argparse.OptionArg(
        "config",
        long="config",
        about="Configuration path (default .moongate.json)",
      ),
      @argparse.OptionArg(
        "config-ref",
        long="config-ref",
        about="Read the configuration from this commit instead of the working tree",
      ),
      @argparse.OptionArg(
        "format",
        long="format",
        about="Output format: text, json or github",
      ),
    ],
  )
  @argparse.Command(
    "moongate",
    about="Semantic CI gatekeeper",
    version=version,
    subcommands=[validate, check],
  )
}

///|
fn single(matches : @argparse.Matches, name : String, fallback : String) -> String {
  match matches.values.get(name) {
    Some(values) => if values.is_empty() { fallback } else { values[values.length() - 1] }
    None => fallback
  }
}

///|
fn optional(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => if values.is_empty() { None } else { Some(values[values.length() - 1]) }
    None => None
  }
}

///|
async fn emit_out(text : String) -> Unit {
  if !text.is_empty() {
    (@host.current().write_stdout)(text) catch {
      _ => ()
    }
  }
}

///|
async fn emit_err(text : String) -> Unit {
  if !text.is_empty() {
    (@host.current().write_stderr)(text) catch {
      _ => ()
    }
  }
}

///|
/// Parses arguments and runs the requested command, returning the exit code.
/// The executable's entry point installs a host backend and exits with it.
pub async fn run() -> Int {
  let argv = (@host.current().args)() catch {
    _ => []
  }
  let args = if argv.length() > 1 { argv[1:].to_owned() } else { [] }
  let command = build_command()
  let matches = try command.parse(argv=args[:]) catch {
    err => {
      emit_err(@core.sanitize_block(err.to_string()) + "\n")
      return 2
    }
  }
  match matches.subcommand {
    None => {
      emit_out(@core.sanitize_block(command.render_help()) + "\n")
      2
    }
    Some(("validate", sub)) => run_validate(sub)
    Some(("check", sub)) => run_check_command(sub)
    Some((name, _)) => {
      emit_err("Unknown subcommand '\{@core.sanitize_line(name)}'.\n")
      2
    }
  }
}

///|
async fn run_validate(matches : @argparse.Matches) -> Int {
  let format = try @core.parse_format(single(matches, "format", "text")) catch {
    err => {
      emit_err(@core.safe_message(err) + "\n")
      return 2
    }
  }
  let path = single(matches, "config", ".moongate.json")
  match (try @runner.validate_config(path) catch {
    err => Err(@core.safe_message(err))
  } noraise {
    config => Ok(config)
  }) {
    Ok(config) => {
      emit_out(@core.render_validation(Some(config.rules.length()), [], format))
      0
    }
    Err(message) => {
      let text = @core.render_validation(None, [message], format)
      match format {
        @core.FormatText => emit_err(text)
        _ => emit_out(text)
      }
      2
    }
  }
}

///|
/// The JSON report shares stderr with diagnostics and with anything the host
/// runtime prints there, so it is framed by lines no report can contain.
let report_begin : String = "--- moongate report begin ---"

///|
let report_end : String = "--- moongate report end ---"

///|
async fn run_check_command(matches : @argparse.Matches) -> Int {
  let format = try @core.parse_format(single(matches, "format", "text")) catch {
    err => {
      emit_err(@core.safe_message(err) + "\n")
      return 2
    }
  }
  let options : @runner.CheckOptions = {
    base: single(matches, "base", ""),
    head: single(matches, "head", "HEAD"),
    config_path: single(matches, "config", ".moongate.json"),
    config_ref: optional(matches, "config-ref"),
  }
  if options.base.is_empty() {
    emit_err("--base is required.\n")
    return 2
  }
  let report = @runner.check(options)
  emit_out(@core.render_report(report, format))
  // A caller that consumes annotations on stdout still needs the structured
  // result; re-running `check` to get it would mean a second paid evaluation.
  // stderr also carries diagnostics and whatever the host runtime decides to
  // print there, so the document is framed rather than left to be found.
  if matches.flags.get("report-json") is Some(true) {
    emit_err(
      report_begin +
      "\n" +
      @core.render_report(report, @core.FormatJson) +
      report_end +
      "\n",
    )
  }
  report.exit_code()
}

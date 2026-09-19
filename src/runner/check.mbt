///|
pub(all) struct CheckOptions {
  base : String
  head : String
  config_path : String
  config_ref : String?
}

///|
priv struct Applicable {
  rule : @core.Rule
  paths : Array[String]
  state : Json
  canonical : String
}

///|
priv struct Acc {
  mut base : String?
  mut head : String?
  mut merge_base : String?
  mut config_ref : String?
  mut model : String
  order : Array[String]
  results : Array[@core.RuleResult]
  errors : Array[String]
}

///|
/// Runs a full evaluation. Never raises: every failure becomes a safe
/// diagnostic in the report, which then concludes `incomplete` (exit 2).
pub async fn check(options : CheckOptions) -> @core.Report {
  let acc = {
    base: None,
    head: None,
    merge_base: None,
    config_ref: None,
    model: @core.default_model,
    order: [],
    results: [],
    errors: [],
  }
  try run_check(options, acc) catch {
    err => acc.errors.push(@core.safe_message(err))
  }
  {
    base: acc.base,
    head: acc.head,
    merge_base: acc.merge_base,
    config_ref: acc.config_ref,
    requested_model: acc.model,
    results: ordered_results(acc),
    errors: acc.errors,
  }
}

///|
/// Reports results in configuration rule order.
///
/// Results are produced out of order (not-applicable during selection, then
/// evidence errors, then per-batch answers), but a reader compares a report
/// against the configuration file, so the file's order is what ships.
fn ordered_results(acc : Acc) -> Array[@core.RuleResult] {
  let rank : Map[String, Int] = Map([])
  for i, id in acc.order {
    if !rank.contains(id) {
      rank[id] = i
    }
  }
  let unknown = acc.order.length()
  let out = acc.results.copy()
  out.sort_by_key(fn(result) { rank.get(result.id).unwrap_or(unknown) })
  out
}

///|
async fn run_check(options : CheckOptions, acc : Acc) -> Unit raise {
  assert_repo_root()
  let base = resolve_commit(options.base, "base")
  let head = resolve_commit(options.head, "head")
  acc.base = Some(base)
  acc.head = Some(head)
  let config_text = match options.config_ref {
    Some(ref_name) => {
      let oid = resolve_commit(ref_name, "config ref")
      acc.config_ref = Some(oid)
      config_from_commit(oid, options.config_path)
    }
    None => read_local_config(options.config_path)
  }
  let config = @core.parse_config(config_text)
  acc.model = config.model
  for rule in config.rules {
    acc.order.push(rule.id)
  }
  let mb = merge_base(base, head)
  acc.merge_base = Some(mb)
  let records = raw_changes(mb, head)
  let applicable : Array[Applicable] = []
  for rule in config.rules {
    let selection = select_records(rule, records)
    if selection.is_empty() {
      acc.results.push({
        id: rule.id,
        status: @core.StatusNotApplicable,
        severity: rule.severity,
        source: rule.source,
        message: rule.message,
        paths: [],
        model: None,
        answer: None,
        detail: None,
      })
      continue
    }
    let paths : Array[String] = []
    for record in selection {
      paths.push(record.key())
    }
    match (try build_state(base, head, mb, selection, rule) catch {
      err => Err(@core.safe_message(err))
    } noraise {
      state => Ok(state)
    }) {
      Err(message) => {
        // A rule whose evidence cannot be represented is a fact about that
        // rule; its severity decides whether the run fails.
        acc.results.push({
          id: rule.id,
          status: @core.StatusError,
          severity: rule.severity,
          source: rule.source,
          message: rule.message,
          paths,
          model: None,
          answer: None,
          detail: Some(message),
        })
      }
      Ok(state) =>
        applicable.push({
          rule,
          paths,
          state,
          canonical: state.stringify(),
        })
    }
  }
  if applicable.is_empty() {
    return
  }
  evaluate_all(config.model, applicable, acc)
}

///|
/// Groups rules that share byte-identical evidence, packs each group into
/// requests that fit the byte budget, and evaluates them sequentially.
async fn evaluate_all(
  model : String,
  applicable : Array[Applicable],
  acc : Acc,
) -> Unit raise {
  // Credentials are required before any request is attempted, so a missing
  // key fails fast instead of half-way through a batch sequence.
  api_key() |> ignore
  let batches : Array[Array[Applicable]] = []
  let pending : Array[Applicable] = []
  for item in applicable {
    pending.push(item)
  }
  let grouped : Array[Array[Applicable]] = []
  let used : Array[Bool] = Array::make(pending.length(), false)
  for i = 0; i < pending.length(); i = i + 1 {
    if used[i] {
      continue
    }
    let group : Array[Applicable] = [pending[i]]
    used[i] = true
    for j = i + 1; j < pending.length(); j = j + 1 {
      if !used[j] && pending[j].canonical == pending[i].canonical {
        group.push(pending[j])
        used[j] = true
      }
    }
    grouped.push(group)
  }
  let oversized : Array[Applicable] = []
  for group in grouped {
    let state = group[0].state
    let current : Array[@core.Rule] = []
    let members : Array[Applicable] = []
    for item in group {
      let single = build_request(model, state, [item.rule][:])
      if json_bytes(single) > max_request_bytes {
        oversized.push(item)
        continue
      }
      current.push(item.rule)
      members.push(item)
      if json_bytes(build_request(model, state, current[:])) > max_request_bytes {
        current.pop() |> ignore
        members.pop() |> ignore
        batches.push(members.copy())
        current.clear()
        members.clear()
        current.push(item.rule)
        members.push(item)
      }
    }
    if !members.is_empty() {
      batches.push(members)
    }
  }
  for item in oversized {
    acc.results.push({
      id: item.rule.id,
      status: @core.StatusError,
      severity: item.rule.severity,
      source: item.rule.source,
      message: item.rule.message,
      paths: item.paths,
      model: None,
      answer: None,
      detail: Some(
        "Evidence is larger than the \{max_request_bytes} byte request budget; narrow the rule's globs or split the change.",
      ),
    })
  }
  let mut failed = false
  let mut failure = ""
  for batch in batches {
    if failed {
      for item in batch {
        acc.results.push({
          id: item.rule.id,
          status: @core.StatusError,
          severity: item.rule.severity,
          source: item.rule.source,
          message: item.rule.message,
          paths: item.paths,
          model: None,
          answer: None,
          detail: Some("Not evaluated: an earlier batch failed."),
        })
      }
      continue
    }
    let rules : Array[@core.Rule] = []
    for item in batch {
      rules.push(item.rule)
    }
    match (try evaluate(model, batch[0].state, rules[:]) catch {
      err => Err(@core.safe_message(err))
    } noraise {
      response => Ok(response)
    }) {
      Err(message) => {
        failed = true
        failure = message
        for item in batch {
          acc.results.push({
            id: item.rule.id,
            status: @core.StatusError,
            severity: item.rule.severity,
            source: item.rule.source,
            message: item.rule.message,
            paths: item.paths,
            model: None,
            answer: None,
            detail: None,
          })
        }
      }
      Ok(response) =>
        for item in batch {
          let answer = response.answers[item.rule.id]
          let status = match @core.decide(item.rule, answer) {
            @core.DecideViolation => @core.StatusViolation
            @core.DecideCompliant => @core.StatusCompliant
            @core.DecideReview => @core.StatusReview
          }
          acc.results.push({
            id: item.rule.id,
            status,
            severity: item.rule.severity,
            source: item.rule.source,
            message: item.rule.message,
            paths: item.paths,
            model: Some(response.model),
            answer: Some(answer),
            detail: None,
          })
        }
    }
  }
  if failed {
    acc.errors.push(failure)
  }
}

///|
fn select_records(
  rule : @core.Rule,
  records : Array[ChangeRecord],
) -> Array[ChangeRecord] {
  let out : Array[ChangeRecord] = []
  for record in records {
    let mut hit = false
    match record.old_path {
      Some(path) =>
        if @core.selected(rule.globs, rule.exclude, path) {
          hit = true
        }
      None => ()
    }
    match record.new_path {
      Some(path) =>
        if @core.selected(rule.globs, rule.exclude, path) {
          hit = true
        }
      None => ()
    }
    if hit {
      out.push(record)
    }
  }
  out
}

///|
/// Assembles the complete evidence unit for one rule. A cross-file rule is
/// never split, so it can never pass on a fragment of its evidence.
async fn build_state(
  base : String,
  head : String,
  mb : String,
  records : Array[ChangeRecord],
  rule : @core.Rule,
) -> Json raise {
  let changes : Array[Json] = []
  for record in records {
    let patch = record_patch(record)
    changes.push(
      Json::object({
        "status": Json::string(record.status),
        "old_path": match record.old_path {
          Some(path) => Json::string(path)
          None => Json::null()
        },
        "new_path": match record.new_path {
          Some(path) => Json::string(path)
          None => Json::null()
        },
        "old_mode": Json::string(record.old_mode),
        "new_mode": Json::string(record.new_mode),
        "patch": Json::string(patch),
      }),
    )
  }
  let context_paths = rule.context.copy()
  context_paths.sort()
  let context : Array[Json] = []
  for path in context_paths {
    let before = context_text(mb, path)
    let after = context_text(head, path)
    if before is None && after is None {
      raise @core.GateError(
        "Context path '\{@core.sanitize_line(path)}' does not exist at either revision.",
      )
    }
    context.push(
      Json::object({
        "path": Json::string(path),
        "before": match before {
          Some(text) => Json::string(text)
          None => Json::null()
        },
        "after": match after {
          Some(text) => Json::string(text)
          None => Json::null()
        },
      }),
    )
  }
  Json::object({
    "base": Json::string(base),
    "head": Json::string(head),
    "merge_base": Json::string(mb),
    "changes": Json::array(changes),
    "context": Json::array(context),
  })
}

///|
/// Reads a working-tree configuration file.
pub async fn read_local_config(path : String) -> String raise {
  let kind = (@host.current().path_kind)(path)
  if kind is @host.Missing {
    raise @core.GateError(
      "Configuration '\{@core.sanitize_line(path)}' not found.",
    )
  }
  if !(kind is @host.Regular) {
    raise @core.GateError(
      "Configuration '\{@core.sanitize_line(path)}' is not a regular file.",
    )
  }
  let size = (@host.current().file_size)(path)
  if size > @core.max_config_bytes.to_int64() {
    raise @core.GateError("Configuration exceeds the 1 MiB limit.")
  }
  let data = (@host.current().read_file)(path)
  try @utf8.decode(data[:]) catch {
    _ => raise @core.GateError("Configuration is not valid UTF-8.")
  }
}

///|
/// Validates a configuration file without touching Git or the network.
pub async fn validate_config(path : String) -> @core.Config raise {
  @core.parse_config(read_local_config(path))
}

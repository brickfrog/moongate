///|
/// Runs every scenario. An aborted scenario is a failure: a broken fixture
/// invalidates the checks that would have followed it.
async fn run_scenarios(fixture : Fixture) -> Unit {
  scenario("config rejections", () => test_config_rejections())
  scenario("result order", () => test_result_order_follows_config(fixture))
  scenario("literal context paths", () => test_context_paths_are_literal(fixture))
  scenario("glob and selection", () => test_glob_and_selection(fixture))
  scenario("merge base", () => test_merge_base(fixture))
  scenario("base policy", () => test_config_ref_policy(fixture))
  scenario("hostile paths", () => test_hostile_paths(fixture))
  scenario("git config isolation", () => test_attribute_and_driver_isolation(fixture))
  scenario("file to directory", () => test_file_to_directory(fixture))
  scenario("unsupported evidence", () => test_unsupported_evidence(fixture))
  scenario("credentials", () => test_credentials(fixture))
  scenario("policy thresholds", () => test_policy_thresholds(fixture))
  scenario("transport failures", () => test_transport_failures(fixture))
  scenario("batching", () => test_batching(fixture))
  scenario("action entry point", () => test_action_entry_point(fixture))
  scenario("large report", () => test_large_report_is_not_truncated(fixture))
}

///|
async fn scenario(name : String, body : async () -> Unit raise) -> Unit {
  body() catch {
    err => failures.push("\{name} aborted: \{err}")
  }
}

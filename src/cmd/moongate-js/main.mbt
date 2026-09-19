///|
/// Node entry point.
async fn main {
  let backend = @js.host()
  @host.install(backend)
  let code = @cli.run() catch {
    _ => 2
  }
  (backend.exit)(code)
}

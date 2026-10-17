# frozen_string_literal: true

module AxumDsl
  # IR -> Rust text for an axum service: Cargo.toml, src/main.rs, any injected module, and the source
  # map CargoBuild reads. No Prism from here on.
  #
  # One #[derive] struct per (params block, request source) a route needs. The reader resolves each
  # field's source into the route's `field_in`, so a block whose fields arrive in the query string and
  # in the body becomes two structs, each named after the block and the source it reads. A params block
  # another struct nests keeps its declared name and one plain struct.
  #
  # A handler answers with ::axum::response::Response, the type Body lowers every route body to:
  # json/text/html/halt/redirect are already one, and a plain string becomes one through IntoResponse,
  # Sinatra's rule for a body that ends in a string. A body that can fail runs in a closure whose error
  # goes to the `error` filter, or to a plain 500 when no filter is declared.
  #
  # Every emitted line of a declaration is recorded against the DSL line that produced it, in the map
  # CargoBuild::MAP names, so rustc's error at src/main.rs:N is reported at FILE:LINE in the DSL. A
  # `before`, `not_found` or `error` body carries its own line and file too (Reader#filter_decl), so a
  # filter is mapped like every other declaration.
  module Emit
    # Rust helper for cmd_fn / script_fn. Arguments are separate argv entries (never shell
    # text); the environment is reduced to PATH; 10 s timeout; 1 MB output cap.
    RUN_SUBPROCESS = <<~'RS'
      fn run_subprocess(program: &str, argv: &[String], stdin: Option<&str>) -> String {
          use std::io::{Read, Write};
          use std::process::{Command, Stdio};
          use std::time::{Duration, Instant};

          const TIMEOUT: Duration = Duration::from_secs(10);
          const MAX_OUT: u64 = 1_000_000;

          let mut child = match Command::new(program)
              .args(argv)
              .env_clear()
              .env("PATH", std::env::var_os("PATH").unwrap_or_default())
              .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
              .stdout(Stdio::piped())
              .stderr(Stdio::piped())
              .spawn()
          {
              Ok(child) => child,
              Err(e) => return format!("error: cannot start {program}: {e}"),
          };
          let out = child.stdout.take();
          let err = child.stderr.take();
          let read_out = std::thread::spawn(move || {
              let mut buf = Vec::new();
              if let Some(r) = out {
                  let _ = r.take(MAX_OUT + 1).read_to_end(&mut buf);
              }
              buf
          });
          let read_err = std::thread::spawn(move || {
              let mut buf = Vec::new();
              if let Some(r) = err {
                  let _ = r.take(MAX_OUT).read_to_end(&mut buf);
              }
              buf
          });
          if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
              let _ = pipe.write_all(text.as_bytes());
          }
          let start = Instant::now();
          let status = loop {
              match child.try_wait() {
                  Ok(Some(status)) => break status,
                  Ok(None) if start.elapsed() > TIMEOUT => {
                      let _ = child.kill();
                      let _ = child.wait();
                      return format!("error: {program} timed out after {} s", TIMEOUT.as_secs());
                  }
                  Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                  Err(e) => return format!("error: waiting for {program}: {e}"),
              }
          };
          let out_bytes = read_out.join().unwrap_or_default();
          if out_bytes.len() as u64 > MAX_OUT {
              return format!("error: {program} produced more than {MAX_OUT} bytes of output");
          }
          let stdout = String::from_utf8_lossy(&out_bytes).into_owned();
          let stderr = String::from_utf8_lossy(&read_err.join().unwrap_or_default()).into_owned();
          if status.success() {
              stdout.strip_suffix('\n').unwrap_or(&stdout).to_string()
          } else {
              format!("error: {program} exited with {status}: {}", stderr.trim())
          }
      }
    RS

    # Overflow-checked integer arithmetic. Ruby integers never overflow, so rather than panic
    # (debug) or wrap (release), a failing operation returns text that says what went wrong,
    # where, and how to fix it. Only the operations a server actually uses are emitted (one small
    # function per operation and type), so generated code has no unused items and rustc's
    # dead-code warning stays a real check on this generator.
    ARITH_ERROR = <<~'RS'
      fn arith_error(op: &str, a: impl std::fmt::Display, b: impl std::fmt::Display, b_is_zero: bool, ty: &str, min: i128, max: i128, at: &str) -> String {
          if b_is_zero && (op == "/" || op == "%") {
              format!("error: division by zero at {at}: {a} {op} 0. Fix: check that the divisor is not zero before dividing, or reject that input.")
          } else {
              let fix = if ty == "i64" {
                  "i64 is already the widest integer type here, so limit the input range before this operation"
              } else {
                  "declare the field as :i64 for a wider range, or limit the input range before this operation"
              };
              format!("error: integer overflow at {at}: {a} {op} {b} does not fit in {ty} ({min}..={max}). Fix: {fix}.")
          }
      }
    RS

    # kind => [operator shown in messages, Rust expression over a and b returning an Option].
    # fdiv / fmod round down like Ruby; div / rem truncate like Rust (Rust::Int32 operands).
    CHECKED_BIN = {
      "add" => ["+", "a.checked_add(b)"],
      "sub" => ["-", "a.checked_sub(b)"],
      "mul" => ["*", "a.checked_mul(b)"],
      "div" => ["/", "a.checked_div(b)"],
      "rem" => ["%", "a.checked_rem(b)"],
      "fdiv" => ["/", "a.checked_div(b).and_then(|q| { let r = a % b; if r != 0 && ((r < 0) != (b < 0)) { q.checked_sub(1) } else { Some(q) } })"],
      "fmod" => ["%", "a.checked_rem(b).and_then(|r| if r != 0 && ((r < 0) != (b < 0)) { r.checked_add(b) } else { Some(r) })"]
    }.freeze
    # String#to_i with Ruby's rules (leading whitespace, optional sign, digits with single underscores
    # between them, stop at anything else, no digits is 0), returning an i64. A value that does not
    # fit is an error: Ruby would return a bignum, and a silent wrong number is worse. The shim catalog
    # test (bin/gen_shim_tests) pastes this same text, so Ruby and Rust are compared on its examples.
    STR_TO_I = <<~'RS'
      fn str_to_i(s: &str, at: &str) -> Result<i64, String> {
          let mut chars = s
              .trim_start_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'))
              .chars()
              .peekable();
          let negative = match chars.peek() {
              Some('-') => {
                  chars.next();
                  true
              }
              Some('+') => {
                  chars.next();
                  false
              }
              _ => false,
          };
          let mut value: i128 = 0;
          let mut overflow = false;
          let mut after_digit = false;
          while let Some(&c) = chars.peek() {
              if c.is_ascii_digit() {
                  chars.next();
                  after_digit = true;
                  if !overflow {
                      match value.checked_mul(10).and_then(|v| v.checked_add(c as i128 - '0' as i128)) {
                          Some(v) if v <= i64::MAX as i128 + 1 => value = v,
                          _ => overflow = true,
                      }
                  }
              } else if c == '_' && after_digit {
                  chars.next();
                  match chars.peek() {
                      Some(d) if d.is_ascii_digit() => {}
                      _ => break,
                  }
              } else {
                  break;
              }
          }
          let signed = if negative { -value } else { value };
          if overflow || signed > i64::MAX as i128 || signed < i64::MIN as i128 {
              return Err(format!(
                  "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                  i64::MIN,
                  i64::MAX
              ));
          }
          Ok(signed as i64)
      }
    RS
    # Integer(text, 10): strict decimal parsing. Surrounding whitespace, a sign and single underscores
    # between digits are accepted; anything else is an error, as Ruby raises ArgumentError. i64 result,
    # with an overflow error instead of a bignum. Pasted into the shim test file like STR_TO_I.
    STR_TO_INT = <<~'RS'
      fn str_to_int(s: &str, at: &str) -> Result<i64, String> {
          let t = s.trim_matches(|c: char| matches!(c, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r'));
          let (negative, digits) = match t.as_bytes().first() {
              Some(b'-') => (true, &t[1..]),
              Some(b'+') => (false, &t[1..]),
              _ => (false, t),
          };
          let well_formed = !digits.is_empty()
              && !digits.starts_with('_')
              && !digits.ends_with('_')
              && !digits.contains("__")
              && digits.chars().all(|c| c.is_ascii_digit() || c == '_');
          if !well_formed {
              return Err(format!("error: invalid value for Integer(): {s:?} at {at}"));
          }
          let mut value: i128 = 0;
          for c in digits.chars().filter(|c| *c != '_') {
              match value.checked_mul(10).and_then(|v| v.checked_add(c as i128 - '0' as i128)) {
                  Some(v) if v <= i64::MAX as i128 + 1 => value = v,
                  _ => {
                      return Err(format!(
                          "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                          i64::MIN,
                          i64::MAX
                      ))
                  }
              }
          }
          let signed = if negative { -value } else { value };
          if signed > i64::MAX as i128 || signed < i64::MIN as i128 {
              return Err(format!(
                  "error: integer overflow at {at}: {s:?} does not fit in i64 ({}..={}). Fix: check the length of the input before converting it.",
                  i64::MIN,
                  i64::MAX
              ));
          }
          Ok(signed as i64)
      }
    RS

    # The HTML escaper h(...) lowers to: one pass over the value, and a Cow so a value with nothing to
    # escape comes back borrowed rather than copied. std only, so no crate is added, and the call site is
    # path-qualified (`axum_dsl_html_escape`), so it needs no `use`. Emitted only when a body uses h(...).
    HTML_ESCAPE = <<~'RS'
      fn axum_dsl_html_escape(input: &str) -> std::borrow::Cow<'_, str> {
          let mut escaped: Option<String> = None;
          let mut copied = 0;
          for (i, c) in input.char_indices() {
              let replacement = match c {
                  '&' => "&amp;",
                  '<' => "&lt;",
                  '>' => "&gt;",
                  '"' => "&quot;",
                  '\'' => "&#39;",
                  _ => continue,
              };
              let out = escaped.get_or_insert_with(|| String::with_capacity(input.len() + 8));
              out.push_str(&input[copied..i]);
              out.push_str(replacement);
              copied = i + c.len_utf8();
          }
          match escaped {
              Some(mut out) => {
                  out.push_str(&input[copied..]);
                  std::borrow::Cow::Owned(out)
              }
              None => std::borrow::Cow::Borrowed(input),
          }
      }
    RS

    # What `use_layer :trace, forwarded: true` puts on the router: the span client_span builds, and the
    # request and response events at INFO, which is the level the subscriber main installs shows.
    FORWARDED_TRACE = "::tower_http::trace::TraceLayer::new_for_http().make_span_with(client_span)" \
                      ".on_request(::tower_http::trace::DefaultOnRequest::new().level(::tracing::Level::INFO))" \
                      ".on_response(::tower_http::trace::DefaultOnResponse::new().level(::tracing::Level::INFO))"

    # What a plain `use_layer :trace` puts on the router. tower-http logs its span and events at DEBUG by
    # default, which the info-level subscriber main installs would hide, so all three are raised to INFO.
    PLAIN_TRACE = "::tower_http::trace::TraceLayer::new_for_http()" \
                  ".make_span_with(::tower_http::trace::DefaultMakeSpan::new().level(::tracing::Level::INFO))" \
                  ".on_request(::tower_http::trace::DefaultOnRequest::new().level(::tracing::Level::INFO))" \
                  ".on_response(::tower_http::trace::DefaultOnResponse::new().level(::tracing::Level::INFO))"

    # The span a forwarded trace layer opens for each request. The client is the first entry of
    # X-Forwarded-For (the visitor, as the nearest proxy saw them), else the address of the peer that
    # connected; the header is whatever the caller sent, so it is only as honest as the proxy in front.
    # Emitted only for `forwarded: true`; the peer comes from the ConnectInfo main_fn serves with.
    CLIENT_SPAN = <<~'RS'
      fn client_span(request: &::axum::extract::Request) -> ::tracing::Span {
          let forwarded = request
              .headers()
              .get("x-forwarded-for")
              .and_then(|value| value.to_str().ok())
              .and_then(|value| value.split(',').next())
              .map(|entry| entry.trim().to_string())
              .filter(|entry| !entry.is_empty());
          let client = forwarded
              .or_else(|| {
                  request
                      .extensions()
                      .get::<::axum::extract::ConnectInfo<::std::net::SocketAddr>>()
                      .map(|peer| peer.0.ip().to_string())
              })
              .unwrap_or_default();
          ::tracing::info_span!("request", method = %request.method(), uri = %request.uri(), client = %client)
      }
    RS

    # What resolves when the service is asked to stop: ctrl-c everywhere, SIGTERM on unix (what a
    # container runtime sends). main_fn hands it to axum's with_graceful_shutdown, so the listener closes
    # and in-flight requests finish before the process exits. Always emitted.
    SHUTDOWN_SIGNAL = <<~'RS'
      async fn shutdown_signal() {
          let ctrl_c = async {
              tokio::signal::ctrl_c().await.expect("cannot listen for ctrl-c");
          };
          #[cfg(unix)]
          let terminate = async {
              tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                  .expect("cannot listen for SIGTERM")
                  .recv()
                  .await;
          };
          #[cfg(not(unix))]
          let terminate = std::future::pending::<()>();
          tokio::select! {
              _ = ctrl_c => {}
              _ = terminate => {}
          }
      }
    RS

    module_function

    def files(ir, src)
      CompositeTypes::Opaque.reset(ir["opaque_types"].to_a) # Emit holds no state: the types a binding owns come from the IR
      main, map = main_rs(ir, src)
      files = { "Cargo.toml" => cargo(ir), "src/main.rs" => main, CargoBuild::MAP => "#{JSON.pretty_generate(map)}\n" }
      ir["modules"].to_a.each { |m| files["src/#{m['name']}.rs"] = m["source"] }
      # A declared asset (a `static` directory or a `serve_file` file) is written at the path it was declared
      # with, so a running service finds it beside the crate Cargo.toml: its working directory is the crate
      # directory, which is what makes a bare ServeDir::new("public") find the copy.
      ir["assets"].to_a.each { |a| files[a["path"]] = a["text"] }
      files
    end

    # name and version are validated in Reader (name regex, SEMVER), so plain interpolation into TOML is
    # safe here. The features are the ones the emitted service can name: "http1" and "tokio" for the
    # server itself, and "query" and "json" for the Query and Json extractors and for the Json response
    # a body's `json(...)` call lowers to. With default-features = false none of them is on, and a missing
    # one is a compile error in the generated crate. tower-http is the same kind of dependency, for the
    # file services a `static` mount or a `serve_file` names (see tower_http_dep). No MCP host is a
    # dependency of this crate.
    def cargo(ir)
      <<~TOML
        [package]
        name = "#{ir['name']}"
        version = "#{ir['version']}"
        edition = "2021"

        [dependencies]
        axum = { version = "0.8", default-features = false, features = [#{axum_features(ir).map { |f| "\"#{f}\"" }.join(", ")}] }
        tokio = { version = "1", features = ["rt-multi-thread", "macros", "net", "signal"#{Sessions.tokio_features(ir)}] }
        serde = { version = "1", features = ["derive"] }
        serde_json = "1"
        anyhow = "1"#{regex_dep(ir)}#{tower_http_dep(ir)}#{tracing_deps(ir)}#{crate_deps(ir)}#{database_deps(ir)}#{Cookies.deps(ir)}#{Sessions.deps(ir)}#{Sanitize.deps(ir)}
      TOML
    end

    # The axum features the emitted service names. The query and json extractors (and the Json response
    # a body's `json(...)` builds) are always on; the "form" feature is added only when a route reads a
    # field `in: :form`, because it is the one that turns on axum's Form extractor. axum's own `query`
    # feature already depends on serde_urlencoded, so Form needs no crate line of its own: there is no
    # serde_urlencoded entry in the generated Cargo.toml, and none is needed.
    def axum_features(ir)
      feats = %w[http1 tokio query json]
      feats << "form" if ir["routes"].to_a.any? { |r| (r["field_in"] || {}).value?("form") }
      feats
    end

    # The database backend's crates (rusqlite and deadpool-sqlite for SQLite), only when `database` is declared.
    def database_deps(ir)
      return "" unless ir["database"]

      Db.backend(ir["database"]["adapter"]).deps.map { |line| "\n#{line}" }.join
    end

    # The database's Rust: its records, the pool and startup checks, and one function per statement, each
    # mapped back to the DSL line that declared it. The backend (Db::Sqlite) writes them; this only places them.
    def database_items(o, ranges, ir)
      Db.backend(ir["database"]["adapter"]).items(ir).each do |decl, what, lines|
        if decl
          mapped(o, ranges, decl, what) { o.concat(lines) }
        else
          o.concat(lines)
        end
        o << ""
      end
    end

    # The regex crate is only a dependency when some body uses a regex literal.
    def regex_dep(ir) = ir["regexes"].to_a.empty? ? "" : "\nregex = \"1\""

    # The tower-http features a file's declarations need, in a fixed order: "fs" when a `static` mount or
    # a `serve_file` needs ServeDir/ServeFile, then one per `use_layer` (Emit::LAYER_FEATURES). A file that
    # names no file service and no layer emits no tower-http line; one that does gets a single line whose
    # feature list is the union, so a file that mounts a directory and compresses gets ["fs",
    # "compression-gzip"], while a file that only says `use_layer :cors` gets ["cors"] and no "fs". 0.6 is
    # the line whose ServeDir has Error = Infallible, which is what axum routing::get_service and
    # Router::nest_service take.
    def tower_http_dep(ir)
      feats = []
      feats << "fs" unless ir["statics"].to_a.empty? && ir["serve_files"].to_a.empty?
      LAYER_ORDER.each { |name| feats << LAYER_FEATURES.fetch(name) if layer?(ir, name) && LAYER_FEATURES.fetch(name) }
      return "" if feats.empty?

      "\ntower-http = { version = \"0.6\", features = [#{feats.map { |f| "\"#{f}\"" }.join(', ')}] }"
    end

    # `use_layer :trace, forwarded: true` names the visitor's address in each request's span, which takes
    # a tracing::Span of its own making. Without `forwarded:` the span is tower-http's own.
    def forwarded?(ir) = !!layer_entry(ir, "trace")&.[]("forwarded")

    # Whether the crate logs: `use_layer :trace` or `set :log` is written. Only then does it depend on
    # tracing and install a subscriber (see subscriber_lines); a service with neither emits neither, so
    # it is byte-for-byte what it was before logging existed. `set :log` without `:trace` still installs
    # the subscriber, so the tracing events of a rust_file or rust_item reach the output.
    def logging?(ir) = layer?(ir, "trace") || !ir["log"].nil?

    # The subscriber's format: `set :log, :json` is JSON lines (tracing-subscriber's `json` feature),
    # anything else is the default text.
    def log_json?(ir) = ir["log"] == "json"

    def tracing_deps(ir)
      return "" unless logging?(ir)

      features = log_json?(ir) ? "\"env-filter\", \"json\"" : "\"env-filter\""
      "\ntracing = \"0.1\"\ntracing-subscriber = { version = \"0.3\", features = [#{features}] }"
    end

    # The statements at the top of main that install the log subscriber. No colour codes in the text
    # format: the lines go to a file or a container's log, where they would only be noise. RUST_LOG
    # overrides the level through EnvFilter (its directive syntax, `warn` or `my_crate=debug`); when it
    # is unset or cannot be parsed the level is info.
    def subscriber_lines(ir)
      [
        "    tracing_subscriber::fmt()",
        *(log_json?(ir) ? ["        .json()"] : ["        .with_ansi(false)"]),
        "        .with_env_filter(",
        "            tracing_subscriber::EnvFilter::try_from_default_env()",
        "                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(\"info\")),",
        "        )",
        "        .init();"
      ]
    end

    # Extra dependencies declared with rust_crate (name, version and features validated in Reader). A crate
    # that names `features:` or `default_features:` is written as a table; any other stays `name = "x"`.
    def crate_deps(ir)
      ir["crates"].to_a.map do |c|
        next "\n#{c['name']} = \"#{c['version']}\"" unless c.key?("features") || c.key?("default_features")

        parts = ["version = \"#{c['version']}\""]
        parts << "default-features = false" if c["default_features"] == false
        parts << "features = [#{c['features'].map { |f| "\"#{f}\"" }.join(", ")}]" if c["features"]
        "\n#{c['name']} = { #{parts.join(", ")} }"
      end.join
    end

    # The suffix a route's struct gets when one params block arrives through more than one part of the
    # request, and the part a field arrives in when the field itself says no `in:` (the reader also
    # resolves this, into "field_in"; the default is repeated here for a route whose block has no
    # fields, where nothing was recorded).
    SOURCE_SUFFIX = { "path" => "Path", "query" => "Query", "body" => "Body", "form" => "Form" }.freeze
    DEFAULT_SOURCE = { "post" => "body", "put" => "body", "patch" => "body" }.freeze

    # The layers `use_layer` names, in the fixed order the emitter puts them on the router, and the
    # tower-http feature each one needs. The order is fixed rather than the declaration order, so where a
    # `use_layer` sits in the file does not change the emitted router. In axum the first `.layer(..)` is
    # the innermost, so the last one listed (trace) sees every request first.
    # :fetch_metadata (Sessions::FETCH_METADATA), :rate_limit (rate_limit_runtime) and :csrf (Csrf::RUNTIME)
    # are the compiler's own middleware, so none needs a feature. :fetch_metadata sits outside :csrf: the
    # cheap cross-site refusal runs first, and the token check is the guard behind it.
    LAYER_ORDER = %w[compression cors timeout csrf fetch_metadata rate_limit trace].freeze
    LAYER_FEATURES = { "compression" => "compression-gzip", "cors" => "cors", "timeout" => "timeout",
                       "fetch_metadata" => nil, "csrf" => nil, "rate_limit" => nil, "trace" => "trace" }.freeze

    def layer?(ir, name) = ir["layers"].to_a.any? { |l| l["name"] == name }

    def layer_entry(ir, name) = ir["layers"].to_a.find { |l| l["name"] == name }

    # The tower-http layer expression for one `use_layer`. `:cors` with `origins:` lists them through
    # HeaderValue::from_static (the reader checked each is a plain origin, so from_static cannot panic);
    # without `origins:` it is CorsLayer::permissive().
    def layer_expr(ir, name)
      case name
      when "compression" then "::tower_http::compression::CompressionLayer::new()"
      when "cors"
        origins = layer_entry(ir, name)&.[]("origins")
        return "::tower_http::cors::CorsLayer::permissive()" unless origins

        list = origins.map { |o| "::axum::http::HeaderValue::from_static(#{AxumDsl.rstr(o)})" }.join(", ")
        "::tower_http::cors::CorsLayer::new().allow_origin([#{list}])"
      # TimeoutLayer::new is deprecated since tower-http 0.6.7, and the generated crate builds with
      # -Dwarnings, so name the status code explicitly (408, which is what new used).
      when "timeout" then "::tower_http::timeout::TimeoutLayer::with_status_code(::axum::http::StatusCode::REQUEST_TIMEOUT, ::std::time::Duration::from_secs(#{layer_entry(ir, name)['secs']}))"
      when "fetch_metadata" then "::axum::middleware::from_fn(axum_dsl_fetch_metadata)"
      when "csrf" then "::axum::middleware::from_fn(axum_dsl_csrf)"
      when "rate_limit" then "::axum::middleware::from_fn(axum_dsl_rate_limit)"
      when "trace" then forwarded?(ir) ? FORWARDED_TRACE : PLAIN_TRACE
      end
    end

    # use_layer :rate_limit: the compiler's own fixed-window limiter, in std only. One process-wide map
    # counts requests per client address (the same address `request_ip` reads) in windows of `per` seconds;
    # a request past `burst` answers 429. `path:` counts one exact path, and without it every route is counted.
    # The three values are this file's, so the runtime is written here rather than in a fixed snippet.
    def rate_limit_runtime(ir)
      entry = layer_entry(ir, "rate_limit")
      path = entry["path"].to_s
      ["// use_layer :rate_limit: one fixed window of requests per client address: written by the compiler",
       "const AXUM_DSL_RATE_LIMIT_PER: u64 = #{entry['per']};",
       "const AXUM_DSL_RATE_LIMIT_BURST: u32 = #{entry['burst']};",
       "const AXUM_DSL_RATE_LIMIT_PATH: &str = #{AxumDsl.rstr(path)};",
       "static AXUM_DSL_RATE_LIMIT: ::std::sync::OnceLock<::std::sync::Mutex<::std::collections::HashMap<String, (u64, u32)>>> =",
       "    ::std::sync::OnceLock::new();",
       "",
       "async fn axum_dsl_rate_limit(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {",
       "    if !AXUM_DSL_RATE_LIMIT_PATH.is_empty() && request.uri().path() != AXUM_DSL_RATE_LIMIT_PATH {",
       "        return next.run(request).await;",
       "    }",
       "    let peer = request.extensions().get::<::axum::extract::ConnectInfo<::std::net::SocketAddr>>().map(|info| info.0);",
       "    let client = axum_dsl_request_ip(request.headers(), peer);",
       "    let now = ::std::time::SystemTime::now()",
       "        .duration_since(::std::time::UNIX_EPOCH)",
       "        .map(|elapsed| elapsed.as_secs())",
       "        .unwrap_or(0);",
       "    let window = now / AXUM_DSL_RATE_LIMIT_PER;",
       "    let over = {",
       "        let cells = AXUM_DSL_RATE_LIMIT.get_or_init(|| ::std::sync::Mutex::new(::std::collections::HashMap::new()));",
       "        let mut counts = match cells.lock() {",
       "            Ok(guard) => guard,",
       "            Err(poisoned) => poisoned.into_inner(),",
       "        };",
       "        let entry = counts.entry(client).or_insert((window, 0));",
       "        if entry.0 != window {",
       "            *entry = (window, 0);",
       "        }",
       "        entry.1 = entry.1.saturating_add(1);",
       "        entry.1 > AXUM_DSL_RATE_LIMIT_BURST",
       "    };",
       "    if over {",
       "        let mut refused = ::axum::response::IntoResponse::into_response(\"rate limit exceeded\");",
       "        *refused.status_mut() = ::axum::http::StatusCode::TOO_MANY_REQUESTS;",
       "        return refused;",
       "    }",
       "    next.run(request).await",
       "}"]
    end

    # One struct per (params block, request source) the routes need, plus one plain struct per params
    # block another struct nests. The plan is also the list of extractors each route takes: path, query
    # and body, in that order, because axum allows only the last extractor to consume the body. A part
    # records the check() the struct needs, so a field's constraint is enforced before the body runs.
    def route_plan(ir)
      blocks = ir["params"].to_a.to_h { |p| [p["name"], p] }
      nested = nested_struct_names(ir)
      taken = {}
      structs = {}
      alloc = lambda do |base, fields, meta|
        sig = fields.map { |f| f["name"] }.join(",")
        name = base
        n = 1
        while taken.key?(name) && taken[name] != sig
          n += 1
          name = "#{base}#{n}"
        end
        unless taken.key?(name)
          taken[name] = sig
          structs[name] = { "name" => name, "fields" => fields }.merge(meta)
        end
        name
      end
      nested.each do |name|
        p = blocks[name] or next
        alloc.call(name, p["fields"], { "owner" => name, "source" => nil, "line" => p["line"], "file" => p["file"] })
      end
      routes = ir["routes"].to_a.map do |r|
        p = blocks[r["params"]]
        parts = []
        if p
          groups = group_sources(r, p)
          single = groups.size == 1 && !nested.include?(p["name"])
          groups.each do |source, fields|
            base = single ? p["name"] : "#{p['name']}#{SOURCE_SUFFIX.fetch(source)}"
            name = alloc.call(base, fields, { "owner" => p["name"], "source" => source, "line" => p["line"], "file" => p["file"] })
            enforced = checked?({ "name" => name, "fields" => fields }, ir)
            # A body that read errors[:field] (body.rb: errors_read) takes this part's check messages into
            # the body instead of the 400 a route that did not read them is answered with.
            parts << { "source" => source, "struct" => name, "binding" => "__#{source}", "fields" => fields,
                       "check" => enforced, "errors" => enforced && r["body"]["errors"] }
          end
        end
        { "route" => r, "parts" => parts }
      end
      { "structs" => structs.values, "routes" => routes }
    end

    # The params blocks another struct nests as a field: a CamelCase field type, or list(X) / map(X).
    # A nested struct keeps its declared name and holds every field, because an object in the body is
    # one JSON value with one shape, whatever the route's verb is.
    def nested_struct_names(ir)
      blocks = ir["params"].to_a.to_h { |p| [p["name"], p] }
      nested = {}
      check = lambda do |bname|
        p = blocks[bname] or next
        p["fields"].each do |f|
          inner = CompositeTypes.nested_struct_name(f["type"])
          next unless inner && !nested[inner]
          nested[inner] = true
          check.call(inner)
        end
      end
      ir["routes"].to_a.filter_map { |r| r["params"] }.uniq.each { |name| check.call(name) }
      nested.keys
    end

    # A route's fields, grouped by the part of the request they arrive in, in the order axum needs
    # (a body extractor last). A group is never empty: a source nothing arrives in is not a struct.
    def group_sources(route, p)
      { "path" => [], "query" => [], "body" => [], "form" => [] }.each_with_object({}) do |(source, _), out|
        fields = p["fields"].select { |f| field_source(route, f) == source }
        out[source] = fields unless fields.empty?
      end
    end

    def field_source(route, f) = (route["field_in"] || {})[f["name"]] || DEFAULT_SOURCE.fetch(route["method"], "query")

    # Which structs need check() and which need check_errors(): the ones a route handler calls, plus the
    # nested structs those methods reach — a nested struct's check() is only called from an outer one's
    # check() or check_errors(), and an uncalled method would be dead code in the generated crate. A struct
    # only an `errors` route uses therefore gets check_errors() and no check(), and one that routes of both
    # kinds use gets both.
    def struct_check_sets(plan, ir)
      by_name = plan["structs"].to_a.to_h { |s| [s["name"], s] }
      checks = {}
      errors = {}
      plan["routes"].each do |e|
        e["parts"].each do |p|
          next unless p["check"]

          (p["errors"] ? errors : checks)[p["struct"]] = true
        end
      end
      queue = checks.keys + errors.keys
      until queue.empty?
        name = queue.pop
        by_name[name]&.[]("fields")&.each do |f|
          inner = CompositeTypes.nested_struct_name(f["type"])
          next unless inner && by_name[inner] && checked?(by_name[inner], ir) && !checks[inner]

          checks[inner] = true
          queue << inner
        end
      end
      [checks.keys, errors.keys]
    end

    # Whether the service declares any setting at all (see settings_runtime).
    def settings?(ir) = !ir["settings"].to_a.empty?
    def mapped(o, ranges, decl, what)
      first = o.size
      yield
      ranges << [first, o.size - 1, decl["line"], what, decl["file"]] if decl["line"]
    end

    # Which main.rs lines each DSL declaration produced, so CargoBuild can point rustc errors
    # back at the DSL. Lines are 1-based and inclusive; an element of `o` may hold newlines.
    def source_map(o, ranges, src)
      start = []
      at = 1
      o.each do |s|
        start << at
        at += 1 + s.count("\n")
      end
      { "source" => src,
        "ranges" => ranges.map do |first, last, line, what, file|
          range = { "from" => start[first], "to" => start[last] + o[last].count("\n"), "dsl_line" => line, "what" => what }
          file ? range.merge("dsl_file" => file) : range
        end }
    end

    # A record's declared fields, checked by rustc against its Rust type: each line reads one field at its declared
    # type and is mapped to that `field` line in the binding, so a Rust struct that drifts from the declaration
    # fails the build there, not at a route. A record is read by cloning, so it must be Clone (the `class` line).
    def record_check(o, ranges, t)
      o << "// a record's fields as its binding declares them (see bindings/), checked here: written by the compiler"
      o << "#[allow(dead_code)]"
      o << "fn check_record_#{t.name.gsub('::', '_').downcase}(r: &#{t.rust}) {"
      mapped(o, ranges, { "line" => t.line, "file" => t.path }, "record #{t.name}") { o << "    let _: #{t.rust} = r.clone();" }
      t.fields.each do |fname, sym, line|
        mapped(o, ranges, { "line" => line, "file" => t.path }, "field `#{fname}` of record #{t.name}") do
          o << "    let _: &#{rust_type(sym)} = &r.#{fname};"
        end
      end
      o << "}"
      o << ""
    end

    # One wrapper per binding function the server calls. The types come from the binding's sig, so
    # rustc checks a `rust "..."` template against them; a Ruby-bodied binding is compiled here.
    def binding_fn(b)
      params = b["args"].map { |n, t| "#{n}: #{rust_type(t, param: true)}" }
      verb = b["async"] ? "async fn" : "fn"
      lines = ["#{verb} #{b['name']}(#{params.join(', ')}) -> #{rust_type(b['returns'])} {"]
      if b["rust"]
        lines << "    #{b['rust']}"
      else
        lines.concat(body_lines(b["body"]).map { |l| "    #{l}" })
      end
      lines << "}"
    end

    # A helper is a plain function over owned values. If its body can fail (raise, return, checked
    # arithmetic, to_i, a helper that can fail) it returns Result<T, String> and callers use `?`.
    def helper_fn(h)
      params = (h["args"].map { |n, t| [n, t] } + h["kw"].to_a.map { |k| [k["name"], k["type"]] })
               .map { |n, t| "#{n}: #{rust_type(t)}" }.join(", ")
      ret = rust_type(h["returns"])
      body = h["body"]
      return async_helper_fn(h, params, ret, body) if h["async"]

      locals = body["locals"].map { |l| "    #{l}" }
      if body["fallible"]
        ["fn helper_#{h['name']}(#{params}) -> Result<#{ret}, String> {", *locals, "    Ok(#{body['expr']})", "}"]
      else
        ["fn helper_#{h['name']}(#{params}) -> #{ret} {", *locals, "    #{body['expr']}", "}"]
      end
    end

    # An async helper's body runs in the async closure `closure_wrap` builds, so `raise`/`return` keep
    # their meaning and the caller awaits: `async fn helper_x(..) -> T { (async || -> T { .. })().await }`.
    def async_helper_fn(h, params, ret, body)
      ok = body["fallible"] ? "Result<#{ret}, String>" : ret
      open, call = closure_wrap(body)
      locals = body["locals"].map { |l| "        #{l}" }
      tail = body["fallible"] ? "        Ok(#{body['expr']})" : "        #{body['expr']}"
      ["async fn helper_#{h['name']}(#{params}) -> #{ok} {",
       "    #{open}#{ok} {",
       *locals,
       tail,
       "    #{call}",
       "}"]
    end

    # The Rust type of a DSL type: parameters borrow (&str, &[String]), results own. Nil-able types are Option.
    def rust_type(type, param: false)
      if CompositeTypes::Opaque.symbol?(type)
        rust = CompositeTypes::Opaque.rust(CompositeTypes::Opaque.name_of(type))
        return param ? "&#{rust}" : rust
      end
      if (inner = Body::OPT[type.to_sym]) && CompositeTypes::Opaque.symbol?(inner)
        return "Option<#{CompositeTypes::Opaque.rust(CompositeTypes::Opaque.name_of(inner))}>"
      end
      if (elem = CompositeTypes::Opaque.list_element(type))
        rust = CompositeTypes::Opaque.rust(elem)
        return param ? "&[#{rust}]" : "Vec<#{rust}>"
      end
      if (inner = Body::OPT[type.to_sym]) && (elem = CompositeTypes::Opaque.list_element(inner))
        return "Option<Vec<#{CompositeTypes::Opaque.rust(elem)}>>"
      end

      case type.to_sym
      when :string then param ? "&str" : "String"
      when :strs then param ? "&[String]" : "Vec<String>"
      when :i64s then param ? "&[i64]" : "Vec<i64>"
      when :f64s then param ? "&[f64]" : "Vec<f64>"
      when :ostr then "Option<String>"
      when :oi64 then "Option<i64>"
      when :oi32 then "Option<i32>"
      when :of64 then "Option<f64>"
      when :obool then "Option<bool>"
      when :ostrs then "Option<Vec<String>>"
      when :oi64s then "Option<Vec<i64>>"
      when :of64s then "Option<Vec<f64>>"
      else TYPES.fetch(type.to_sym)
      end
    end

    # Rust for exactly the checked operations a server uses (keys like "add:i32", "neg:i64").
    def checked_int_lines(used)
      lines = []
      unless used.all? { |u| u.start_with?("neg:") }
        lines.concat(ARITH_ERROR.lines.map(&:chomp))
        lines << ""
      end
      used.each do |key|
        kind, ty = key.split(":")
        if kind == "neg"
          lines << "fn ck_neg_#{ty}(a: #{ty}, at: &str) -> Result<#{ty}, String> {"
          lines << "    a.checked_neg().ok_or_else(|| {"
          lines << "        format!(\"error: integer overflow at {at}: negating {a} does not fit in #{ty} ({}..={}). " \
                   "Fix: limit the input range before negating, or use a wider type.\", #{ty}::MIN, #{ty}::MAX)"
        else
          op, expr = CHECKED_BIN.fetch(kind)
          lines << "fn ck_#{kind}_#{ty}(a: #{ty}, b: #{ty}, at: &str) -> Result<#{ty}, String> {"
          lines << "    #{expr}.ok_or_else(|| {"
          lines << "        arith_error(#{AxumDsl.rstr(op)}, a, b, b == 0, \"#{ty}\", #{ty}::MIN as i128, #{ty}::MAX as i128, at)"
        end
        lines << "    })"
        lines << "}"
        lines << ""
      end
      lines
    end

    # The closure that gives `return` and `raise` their meaning: a `(|| -> ...)()` for a sync body, and an
    # `(async || -> ...)().await` for one that awaits. An async closure is still a `return` boundary, so the
    # emitted `return ...` leaves the closure exactly as before, and it is awaited immediately, so nothing
    # else about the generated function changes. It borrows rather than moves its captures, which the
    # middleware and handler parameters need.
    def closure_wrap(b)
      b["uses_async"] ? ["(async || -> ", "})().await"] : ["(|| -> ", "})()"]
    end

    # A body that can fail (checked arithmetic, `raise`, `return`, to_i, a file read) runs in a closure
    # so `?` and `return Err` can leave it. A binding function has no error channel, so the closure
    # yields the error text as the function's own String result. A body that awaits is async
    # (closure_wrap), awaited at the call site.
    def body_lines(b)
      return b["locals"] + [b["expr"]] unless b["fallible"]

      open, call = closure_wrap(b)
      ["match #{open}Result<String, String> {",
       *b["locals"].map { |l| "    #{l}" },
       "    Ok(#{b['expr']})",
       "#{call} {",
       "    Ok(s) => s,",
       "    Err(e) => e,",
       "}"]
    end

    # The serde attributes of a field. The wire may leave out a field with a default, and serde calls
    # the generated function for it; an optional field is Option<T>, which serde already reads as None
    # when it is absent. A form field may carry a `name:` wire key (a Rails form sends `message[body]`),
    # which is a serde rename: the struct field keeps the DSL name, so the body still reads params[:body]
    # and check()/errors stay keyed by it. Every other constraint is enforced by check(), not by serde.
    def field_attrs(f, struct)
      attrs = []
      attrs << "#[serde(rename = #{AxumDsl.rstr(f['wire_name'])})]" if f["wire_name"]
      attrs << "#[serde(default = \"#{default_name(struct, f)}\")]" if f.key?("default")
      attrs
    end

    # Field options the generated server enforces itself (the wire format only says what the value is).
    CHECKED_OPTIONS = %w[min max exclusive_min exclusive_max multiple_of min_length max_length pattern enum min_items max_items].freeze
    def clone_structs(ir)
      all = ir["params"].to_a.to_h { |p| [p["name"], p] }
      fields = ir["params"].to_a.flat_map { |p| p["fields"] }
      seen = {}
      stack = fields.filter_map { |f| CompositeTypes.object_list_name(f["type"]) || CompositeTypes.object_map_name(f["type"]) }
      until stack.empty?
        name = stack.pop
        next if seen[name]

        seen[name] = true
        p = all[name] or next
        p["fields"].each do |f|
          stack << f["type"] if f["type"].match?(CAMEL)
          inner = CompositeTypes.object_list_name(f["type"]) || CompositeTypes.object_map_name(f["type"])
          stack << inner if inner
        end
      end
      seen
    end

    # Does this params struct (or an object nested in it) have constraints the server enforces itself?
    def checked?(params, ir = nil)
      params["fields"].any? do |f|
        CHECKED_OPTIONS.any? { |k| f.key?(k) } ||
          (ir && (nested = f["type"].match?(CAMEL) ? f["type"] : CompositeTypes.object_list_name(f["type"]) || CompositeTypes.object_map_name(f["type"])) &&
            (inner = ir["params"].find { |x| x["name"] == nested }) && checked?(inner, ir))
      end
    end
    def field_rust_type(type)
      case type
      when "string_list" then "Vec<String>"
      when "i64_list" then "Vec<i64>"
      when "f64_list" then "Vec<f64>"
      when CompositeTypes::MAP_FIELD, CompositeTypes::MAP_OF_MAP_FIELD
        CompositeTypes.map_rust(CompositeTypes.field_symbol(type).then { |s| CompositeTypes.map_value(s) })
      when CompositeTypes::OBJECT_LIST_FIELD then "Vec<#{CompositeTypes.object_list_name(type)}>"
      when CAMEL then type
      when CompositeTypes::OPAQUE_FIELD then CompositeTypes::Opaque.rust(type)
      when CompositeTypes::OPAQUE_LIST_FIELD then "Vec<#{CompositeTypes::Opaque.rust(type[CompositeTypes::OPAQUE_LIST_FIELD, 1])}>"
      else TYPES.fetch(type.to_sym)
      end
    end

    # serde calls this when the field is missing; the field attribute names it.
    def default_fn(struct, f)
      value =
        case f["type"]
        when "string" then "#{AxumDsl.rstr(f['default'])}.to_string()"
        when "f64" then f["default"].to_f.to_s
        when "string_list" then "vec![#{f['default'].map { |v| "#{AxumDsl.rstr(v)}.to_string()" }.join(', ')}]"
        when "i64_list" then "vec![#{f['default'].join(', ')}]"
        when "f64_list" then "vec![#{f['default'].map { |v| v.to_f.to_s }.join(', ')}]"
        else f["default"].to_s
        end
      ["fn #{default_name(struct, f)}() -> #{field_rust_type(f['type'])} {", "    #{value}", "}"]
    end

    def default_name(struct, f) = "default_#{struct.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}_#{f['name']}"

    # A numeric bound as a Rust literal of the field's type (f64 needs a decimal point).
    def bound(field, value) = field["type"] == "f64" ? value.to_f.to_s : value.to_s

    # The impl a params struct enforces its constraints with. check() is what a route that does not read
    # `errors` calls: it returns the first violation, which route_fn answers 400 with before the body runs.
    # check_errors() is the same tests keyed by field name, for a route whose body read errors[:field]
    # (body.rb: errors_read) -- that handler runs its body with this map instead. A struct that routes of
    # both kinds use gets both methods, in one impl.
    def check_impl(params, ir, check: true, errors: false)
      lines = ["impl #{params['name']} {"]
      if check
        body = params["fields"].flat_map { |f| field_checks(f, ir) }
        lines.concat(["    fn check(&self) -> Result<(), String> {", *body.map { |l| "        #{l}" },
                      "        Ok(())", "    }"])
      end
      if errors
        body = params["fields"].flat_map { |f| field_checks(f, ir, collect: true) }
        lines << "" if check
        lines.concat(["    fn check_errors(&self) -> Result<(), std::collections::BTreeMap<String, String>> {",
                      "        let mut errors = std::collections::BTreeMap::new();",
                      *body.map { |l| "        #{l}" },
                      "        if errors.is_empty() { Ok(()) } else { Err(errors) }", "    }"])
      end
      lines << "}"
      lines
    end

    # The "one failing test" of a field, as the lines that report it: check() returns its message, ending
    # the request; the errors map (collect) records it under the field's own name instead.
    def fail_if_for(tests, name, collect)
      lambda do |cond, fmt, *args|
        message = "format!(#{AxumDsl.rstr(fmt)}, #{[name, *args].join(', ')})"
        tests.push("if #{cond} {", "    #{failure_line(name, collect, message)}", "}")
      end
    end

    # How one failing test reports itself. `message` is the Rust expression that builds the text: the
    # format!(..) call a test of its own builds, or the variable a nested struct's check returned (bound
    # as `message`, since only the errors map reads it: failure_var). or_insert keeps a field's first
    # message, so a later test of the same field -- and a later entry of a map of maps -- cannot replace
    # what check() would have reported for it. It is evaluated only where its own condition held.
    def failure_line(name, collect, message)
      return "return Err(#{message});" unless collect

      "errors.entry(#{name}.to_string()).or_insert(#{message});"
    end

    def failure_var(collect) = collect ? "message" : "e"

    # The min_items/max_items checks for a map or list variable `var` (one entry-count test per bound).
    def item_checks(var, f, name, collect = false)
      tests = []
      fail_if = fail_if_for(tests, name, collect)
      fail_if.call("#{var}.len() < #{f['min_items']}", "error: invalid value for {}: it has {} items, fewer than the minimum of {}", "#{var}.len()", f["min_items"].to_s) if f["min_items"]
      fail_if.call("#{var}.len() > #{f['max_items']}", "error: invalid value for {}: it has {} items, more than the maximum of {}", "#{var}.len()", f["max_items"].to_s) if f["max_items"]
      tests
    end

    def field_checks(f, ir, collect: false)
      name = AxumDsl.rstr(f["name"])
      if (oname = CompositeTypes.object_list_name(f["type"])) # a list of objects: size limits and every element
        inner = ir["params"].find { |x| x["name"] == oname }
        tests = []
        fail_if = fail_if_for(tests, name, collect)
        fail_if.call("v.len() < #{f['min_items']}", "error: invalid value for {}: it has {} items, fewer than the minimum of {}", "v.len()", f["min_items"].to_s) if f["min_items"]
        fail_if.call("v.len() > #{f['max_items']}", "error: invalid value for {}: it has {} items, more than the maximum of {}", "v.len()", f["max_items"].to_s) if f["max_items"]
        if inner && checked?(inner, ir)
          tests.push("if let Err(#{failure_var(collect)}) = v.iter().try_for_each(|e| e.check()) {", "    #{failure_line(name, collect, failure_var(collect))}", "}")
        end
        return [] if tests.empty?

        return f["optional"] ? ["if let Some(v) = &self.#{f['name']} {", *tests.map { |l| "    #{l}" }, "}"] : ["{", "    let v = &self.#{f['name']};", *tests.map { |l| "    #{l}" }, "}"]
      end
      if CompositeTypes.map_field_text?(f["type"]) # maps: entry-count bounds, and nested values
        tests = item_checks("v", f, name, collect)
        if (mname = CompositeTypes.object_map_name(f["type"]))
          inner = ir["params"].find { |x| x["name"] == mname }
          tests.push("if let Err(#{failure_var(collect)}) = v.values().try_for_each(|e| e.check()) {", "    #{failure_line(name, collect, failure_var(collect))}", "}") if inner && checked?(inner, ir)
        elsif CompositeTypes.map_of_map_name(f["type"])
          inner = item_checks("inner", f, name, collect)
          tests.push("for inner in v.values() {", *inner.map { |l| "    #{l}" }, "}") unless inner.empty?
        end
        return [] if tests.empty?

        return f["optional"] ? ["if let Some(v) = &self.#{f['name']} {", *tests.map { |l| "    #{l}" }, "}"] : ["{", "    let v = &self.#{f['name']};", *tests.map { |l| "    #{l}" }, "}"]
      end
      if f["type"].match?(CAMEL) # a nested object checks itself
        inner = ir["params"].find { |x| x["name"] == f["type"] }
        return [] unless inner && checked?(inner, ir)

        # A nested object's own check answers one message; the errors map keys it by the field that holds
        # the object, since the map is flat over the route's own fields.
        if f["optional"]
          return ["if let Some(v) = &self.#{f['name']} {", "    if let Err(#{failure_var(collect)}) = v.check() {",
                  "        #{failure_line(name, collect, failure_var(collect))}", "    }", "}"]
        end
        return ["if let Err(#{failure_var(collect)}) = self.#{f['name']}.check() {", "    #{failure_line(name, collect, failure_var(collect))}", "}"]
      end
      tests = []
      fail_if = fail_if_for(tests, name, collect)
      fail_if.call("*v < #{bound(f, f['min'])}", "error: invalid value for {}: {} is below the minimum of {}", "v", AxumDsl.rstr(bound(f, f["min"]))) if f["min"]
      fail_if.call("*v > #{bound(f, f['max'])}", "error: invalid value for {}: {} is above the maximum of {}", "v", AxumDsl.rstr(bound(f, f["max"]))) if f["max"]
      fail_if.call("*v <= #{bound(f, f['exclusive_min'])}", "error: invalid value for {}: {} is not above the exclusive minimum of {}", "v", AxumDsl.rstr(bound(f, f["exclusive_min"]))) if f["exclusive_min"]
      fail_if.call("*v >= #{bound(f, f['exclusive_max'])}", "error: invalid value for {}: {} is not below the exclusive maximum of {}", "v", AxumDsl.rstr(bound(f, f["exclusive_max"]))) if f["exclusive_max"]
      fail_if.call("*v % #{f['multiple_of']} != 0", "error: invalid value for {}: {} is not a multiple of {}", "v", f["multiple_of"].to_s) if f["multiple_of"]
      if f["min_length"]
        fail_if.call("v.chars().count() < #{f['min_length']}", "error: invalid value for {}: it has {} characters, fewer than the minimum of {}",
                     "v.chars().count()", f["min_length"].to_s)
      end
      if f["max_length"]
        fail_if.call("v.chars().count() > #{f['max_length']}", "error: invalid value for {}: it has {} characters, more than the maximum of {}",
                     "v.chars().count()", f["max_length"].to_s)
      end
      if f["min_items"]
        fail_if.call("v.len() < #{f['min_items']}", "error: invalid value for {}: it has {} items, fewer than the minimum of {}", "v.len()", f["min_items"].to_s)
      end
      if f["max_items"]
        fail_if.call("v.len() > #{f['max_items']}", "error: invalid value for {}: it has {} items, more than the maximum of {}", "v.len()", f["max_items"].to_s)
      end
      fail_if.call("!#{f['pattern_id']}.is_match(v)", "error: invalid value for {}: {:?} does not match the pattern {}", "v", AxumDsl.rstr(f["pattern"])) if f["pattern"]
      if f["enum"]
        list = f["enum"].map { |v| AxumDsl.rstr(v) }.join(", ")
        fail_if.call("![#{list}].contains(&v.as_str())", "error: invalid value for {}: {:?} is not one of {}", "v", AxumDsl.rstr(f["enum"].join(", ")))
      end
      return [] if tests.empty?

      if f["optional"]
        ["if let Some(v) = &self.#{f['name']} {", *tests.map { |l| "    #{l}" }, "}"]
      else
        ["{", "    let v = &self.#{f['name']};", *tests.map { |l| "    #{l}" }, "}"]
      end
    end
    # A typed setting (`type: :i64`, `:f64`, `:bool`) is read as text like any other, then parsed with Rust's FromStr; a
    # value that does not parse joins the unreadable-variable problems, so the server does not start on a bad number.
    SETTING_RUST = { "i64" => "i64", "f64" => "f64", "bool" => "bool" }.freeze
    SETTING_EXPECT = { "i64" => "an integer", "f64" => "a number", "bool" => "true or false" }.freeze
    # The settings the server reads from its environment: read once at startup (load_settings, called from main), then
    # read by bodies as settings().name. A value counts as set when it is not empty. A missing or unreadable variable
    # stops the server with a message that names the variables, never their values; Settings has no Debug, so a value
    # cannot be printed by accident either.
    def settings_runtime(ir)
      list = ir["settings"]
      typed = list.any? { |s| s["type"] }
      needs_missing = list.any? { |s| !s["optional"] && !s.key?("default") }
      fields = list.map do |s|
        rust = SETTING_RUST.fetch(s["type"], "String")
        "    #{s['name']}: #{s['optional'] ? "Option<#{rust}>" : rust},"
      end
      reads = list.flat_map do |s|
        env = AxumDsl.rstr(s["env"])
        what = s["description"] ? "#{s['name']}: #{s['description']}" : s["name"]
        next typed_setting_read(s, env, what) if s["type"]

        if s.key?("default")
          ["    let #{s['name']} = read(#{env}, &mut problems).unwrap_or_else(|| #{AxumDsl.rstr(s['default'])}.to_string());"]
        elsif s["optional"]
          ["    let #{s['name']} = read(#{env}, &mut problems);"]
        else
          ["    let #{s['name']} = read(#{env}, &mut problems);",
           "    if #{s['name']}.is_none() {",
           "        missing.push(#{AxumDsl.rstr("  #{s['env']}  (#{what})")});",
           "    }"]
        end
      end
      build = list.map { |s| "        #{s['name']}: #{s['name']}#{s['optional'] || s.key?('default') ? '' : '.unwrap_or_default()'}," }
      ["struct Settings {", *fields, "}", "",
       "static SETTINGS: std::sync::OnceLock<Settings> = std::sync::OnceLock::new();", "",
       "fn settings() -> &'static Settings {",
       "    SETTINGS.get().expect(\"settings are loaded before the server starts\")",
       "}", "",
       "fn load_settings() -> Result<Settings, String> {",
       "    fn read(env: &str, problems: &mut Vec<String>) -> Option<String> {",
       "        match std::env::var(env) {",
       "            Ok(value) if !value.is_empty() => Some(value),",
       "            Ok(_) | Err(std::env::VarError::NotPresent) => None,",
       "            Err(std::env::VarError::NotUnicode(_)) => {",
       "                problems.push(format!(\"  {env} is not valid UTF-8\"));",
       "                None",
       "            }",
       "        }",
       "    }",
       *(typed ? setting_parser : []),
       "    let #{needs_missing ? 'mut ' : ''}missing: Vec<&str> = Vec::new();",
       "    let mut problems: Vec<String> = Vec::new();",
       *reads,
       "    if !missing.is_empty() || !problems.is_empty() {",
       "        let mut message = String::new();",
       "        if !missing.is_empty() {",
       "            message.push_str(\"error: the server needs these environment variables:\\n\");",
       "            message.push_str(&missing.join(\"\\n\"));",
       "            message.push('\\n');",
       "        }",
       "        if !problems.is_empty() {",
       "            message.push_str(\"error: unreadable environment variables:\\n\");",
       "            message.push_str(&problems.join(\"\\n\"));",
       "            message.push('\\n');",
       "        }",
       "        message.push_str(\"Set them in the environment of the process that starts this server (a .env file is not read).\");",
       "        return Err(message);",
       "    }",
       "    Ok(Settings {", *build, "    })",
       "}"]
    end
    def files_runtime(ir)
      files = ir["files"].to_a
      return [] if files.empty?

      out = files.any? { |f| !f["entries"].empty? } ? FILE_CHECK.lines.map(&:chomp) + [""] : []
      files.each do |f|
        name = f["name"]
        built = "std::path::PathBuf::from(#{AxumDsl.rstr(f['path'])})"
        path = f["env"] ? "match std::env::var(#{AxumDsl.rstr(f['env'])}) { Ok(p) if !p.is_empty() => std::path::PathBuf::from(p), _ => #{built} }" : built
        out.push("fn file_path_#{name}() -> std::path::PathBuf {", "    #{path}", "}", "")
        out.push("static FILE_ENTRIES_#{name.upcase}: &[FileEntry] = &[", *file_entry_rows(f), "];", "") unless f["entries"].empty?
        next unless f["text_read"]

        recheck = !f["entries"].empty? && !f["unchecked"].include?("each_read")
        out.push("fn file_text_#{name}() -> Result<String, String> {",
                 "    let path = file_path_#{name}();",
                 "    let text = std::fs::read_to_string(&path).map_err(|e| format!(\"error: cannot read file `#{name}` at {}: {e}\", path.display()))?;",
                 *(recheck ? ["    check_file_entries(#{AxumDsl.rstr(name)}, &path, &text, FILE_ENTRIES_#{name.upcase})?;"] : []),
                 "    Ok(text)", "}", "")
      end
      out.push("fn check_files() -> Result<(), String> {")
      files.each do |f|
        name = f["name"]
        out.push("    {", "        let path = file_path_#{name}();",
                 "        let #{f['entries'].empty? ? '_text' : 'text'} = std::fs::read_to_string(&path).map_err(|e| format!(\"error: cannot read file `#{name}` at {}: {e}\", path.display()))?;")
        out << "        check_file_entries(#{AxumDsl.rstr(name)}, &path, &text, FILE_ENTRIES_#{name.upcase})?;" unless f["entries"].empty?
        out << "    }"
      end
      out.push("    Ok(())", "}", "")
    end

    def file_entry_rows(f)
      f["entries"].map do |e|
        sig = f["sigs"].fetch(e)
        fields = sig["dict_lines"].map { |n, l| "(#{AxumDsl.rstr(n)}, #{AxumDsl.rstr(l)})" }.join(", ")
        "    FileEntry { name: #{AxumDsl.rstr(e)}, header: #{AxumDsl.rstr(sig['header'])}, dict: #{AxumDsl.rstr(sig['dict'])}, fields: &[#{fields}] },"
      end
    end
    # header and, for a TypedDict parameter, its field lines, each with comments dropped and whitespace collapsed.
    # An empty header means the args check is off, so only the `def`'s existence is checked.
    FILE_CHECK = <<~'RS'
      struct FileEntry {
          name: &'static str,
          header: &'static str,
          dict: &'static str,
          fields: &'static [(&'static str, &'static str)],
      }

      fn py_norm(line: &str) -> String {
          let mut out = String::new();
          let mut quote: Option<char> = None;
          for c in line.chars() {
              match quote {
                  Some(q) if c == q => quote = None,
                  Some(_) => {}
                  None if c == '"' || c == '\'' => quote = Some(c),
                  None if c == '#' => break,
                  None => {}
              }
              out.push(c);
          }
          out.split_whitespace().collect::<Vec<_>>().join(" ")
      }

      fn py_top_level(raw: &str) -> bool {
          !raw.starts_with(' ') && !raw.starts_with('\t')
      }

      fn py_def_header(text: &str, name: &str) -> Option<String> {
          let lines: Vec<&str> = text.lines().collect();
          // From the end: Python keeps the last top-level def of a name.
          for (i, raw) in lines.iter().enumerate().rev() {
              let n = py_norm(raw);
              let rest = n.strip_prefix("async ").unwrap_or(&n);
              let Some(after) = rest.strip_prefix("def ") else { continue };
              if !py_top_level(raw) || !after.starts_with(name) || !after[name.len()..].trim_start().starts_with('(') {
                  continue;
              }
              let mut header = Vec::new();
              let mut depth = 0i32;
              let mut opened = false;
              for line in &lines[i..] {
                  let part = py_norm(line);
                  for c in part.chars() {
                      match c {
                          '(' | '[' | '{' => {
                              depth += 1;
                              opened = true;
                          }
                          ')' | ']' | '}' => depth -= 1,
                          _ => {}
                      }
                  }
                  let done = opened && depth == 0 && part.ends_with(':');
                  header.push(part);
                  if done {
                      return Some(header.join(" ").split_whitespace().collect::<Vec<_>>().join(" "));
                  }
              }
              return None;
          }
          None
      }

      fn py_dict_fields(text: &str, dict: &str) -> Option<Vec<(String, String)>> {
          let lines: Vec<&str> = text.lines().collect();
          let start = lines.iter().rposition(|raw| {
              let n = py_norm(raw);
              py_top_level(raw)
                  && n.strip_prefix("class ").is_some_and(|r| r.starts_with(dict) && r[dict.len()..].trim_start().starts_with('('))
          })?;
          let mut out = Vec::new();
          let mut in_doc: Option<&str> = None;
          for raw in &lines[start + 1..] {
              if let Some(q) = in_doc {
                  if raw.contains(q) {
                      in_doc = None;
                  }
                  continue;
              }
              let n = py_norm(raw);
              if !n.is_empty() && py_top_level(raw) {
                  break;
              }
              if n.is_empty() || n == "pass" {
                  continue;
              }
              if let Some(q) = ["\"\"\"", "'''"].into_iter().find(|q| n.starts_with(q)) {
                  if !(n.len() > 3 && n[3..].contains(q)) {
                      in_doc = Some(q);
                  }
                  continue;
              }
              let field = n.split_once(':').map_or(n.as_str(), |(f, _)| f).trim().to_string();
              out.push((field, n));
          }
          Some(out)
      }

      fn check_file_entries(file: &str, path: &std::path::Path, text: &str, entries: &[FileEntry]) -> Result<(), String> {
          let at = path.display();
          for e in entries {
              let Some(header) = py_def_header(text, e.name) else {
                  return Err(format!("error: {at} has no top-level `def {}(` any more, but file `{file}` lists it in entries:; restore it or rebuild the server", e.name));
              };
              if e.header.is_empty() {
                  continue;
              }
              if header != e.header {
                  return Err(format!("error: `def {}` in {at} changed since the server was built (was `{}`, now `{header}`); rebuild the server so its arguments are checked again", e.name, e.header));
              }
              if e.dict.is_empty() {
                  continue;
              }
              let Some(now) = py_dict_fields(text, e.dict) else {
                  return Err(format!("error: {at} has no `class {}(TypedDict)` any more, which `def {}` takes; restore it or rebuild the server", e.dict, e.name));
              };
              for (name, line) in e.fields {
                  match now.iter().find(|(n, _)| n.as_str() == *name) {
                      None => return Err(format!("error: {at}: field `{name}` of {} is gone; rebuild the server", e.dict)),
                      Some((_, l)) if l.as_str() != *line => {
                          return Err(format!("error: {at}: field `{name}` of {} changed (was `{line}`, now `{l}`); rebuild the server", e.dict));
                      }
                      _ => {}
                  }
              }
              if let Some((n, _)) = now.iter().find(|(n, _)| !e.fields.iter().any(|(f, _)| *f == n.as_str())) {
                  return Err(format!("error: {at}: {} has a field `{n}` the server was built without; rebuild the server", e.dict));
              }
          }
          Ok(())
      }
    RS
    # The read of one typed setting: the raw text, the missing check for a required one, then the parse.
    def typed_setting_read(s, env, what)
      name = s["name"]
      parse = "parse_setting::<#{SETTING_RUST.fetch(s['type'])}>(#{env}, #{name}_raw, #{AxumDsl.rstr(SETTING_EXPECT.fetch(s['type']))}, &mut problems)"
      lines = ["    let #{name}_raw = read(#{env}, &mut problems);"]
      if s.key?("default")
        lines << "    let #{name} = #{parse}.unwrap_or(#{setting_default_rust(s)});"
      elsif s["optional"]
        lines << "    let #{name} = #{parse};"
      else
        lines.push("    if #{name}_raw.is_none() {",
                   "        missing.push(#{AxumDsl.rstr("  #{s['env']}  (#{what})")});",
                   "    }",
                   "    let #{name} = #{parse};")
      end
      lines
    end

    def setting_default_rust(s)
      v = s["default"]
      case s["type"]
      when "f64" then Float(v).to_s
      when "i64" then v.negative? ? "(#{v})" : v.to_s
      else v.to_s
      end
    end

    # parse_setting reads a typed setting's text; a failure names the variable and the kind of value it wanted, never the
    # value itself.
    def setting_parser
      ["    fn parse_setting<T: std::str::FromStr>(env: &str, raw: Option<String>, expect: &str, problems: &mut Vec<String>) -> Option<T> {",
       "        let raw = raw?;",
       "        match raw.trim().parse::<T>() {",
       "            Ok(value) => Some(value),",
       "            Err(_) => {",
       "                problems.push(format!(\"  {env} is not {expect}\"));",
       "                None",
       "            }",
       "        }",
       "    }"]
    end
    # One wrapper per cmd_fn/script_fn: fixed argv prefix, then the call arguments.
    def subproc_fn(sp)
      params = sp["args"].each_with_index.map { |t, i| "a#{i}: #{t == 'string' ? '&str' : TYPES.fetch(t.to_sym)}" }
      prefix = sp["argv"].map { |s| "#{AxumDsl.rstr(s)}.to_string()" }
      stdin = sp["pass"] == "stdin"
      mut = !stdin && !sp["args"].empty? ? "mut " : ""
      lines = ["fn #{sp['name']}(#{params.join(', ')}) -> String {",
               "    let #{mut}argv: Vec<String> = vec![#{prefix.join(', ')}];"]
      if stdin
        lines << "    run_subprocess(#{AxumDsl.rstr(sp['program'])}, &argv, Some(a0))"
      else
        sp["args"].each_index { |i| lines << "    argv.push(a#{i}.to_string());" }
        lines << "    run_subprocess(#{AxumDsl.rstr(sp['program'])}, &argv, None)"
      end
      lines << "}"
    end

    def regex_test(regexes)
      return [] if regexes.empty?

      [
        "",
        "#[cfg(test)]",
        "mod tests {",
        "    use super::*;",
        "",
        "    #[test]",
        "    fn regexes_compile() {",
        *regexes.map { |r| "        LazyLock::force(&#{r['id']});" },
        "    }",
        "}"
      ]
    end

    def main_rs(ir, src)
      plan = route_plan(ir)
      regexes = ir["regexes"].to_a
      o = []
      ranges = []
      o << "// Generated by axum_dsl #{VERSION} from #{File.basename(src)}. Do not edit."
      # Every axum path is written out in full (axum::extract::Query<..>), so the only `use` lines are
      # the two a regex literal needs.
      ir["modules"].to_a.each { |m| o << "mod #{m['name']};" }
      o << "" unless ir["modules"].to_a.empty?
      checks, error_impls = struct_check_sets(plan, ir)
      clones = clone_structs(ir) # a struct whose value a body clones (a list or map element) must derive Clone
      plan["structs"].each do |s|
        mapped(o, ranges, s, "params `#{s['owner']}`") do
          derives = []
          derives << "Clone" if clones.key?(s["owner"])
          derives << "serde::Serialize" << "serde::Deserialize" # json(..) serialises a value, so both are derived
          o << "#[derive(#{derives.join(', ')})]"
          o << "struct #{s['name']} {"
          s["fields"].each do |f|
            field_attrs(f, s["name"]).each { |a| o << "    #{a}" }
            ty = field_rust_type(f["type"])
            o << "    #{f['name']}: #{f['optional'] ? "Option<#{ty}>" : ty},"
          end
          o << "}"
        end
        s["fields"].select { |f| f.key?("default") }.each { |f| o.concat(["", *default_fn(s["name"], f)]) }
        o << ""
      end
      # An impl outside the struct's own mapped block, so the ranges do not overlap. A struct that routes
      # of both kinds use gets check() and check_errors() in the one impl.
      plan["structs"].each do |s|
        want_check = checks.include?(s["name"])
        want_errors = error_impls.include?(s["name"])
        next unless want_check || want_errors

        mapped(o, ranges, s, "params `#{s['owner']}` (constraints)") { o.concat(check_impl(s, ir, check: want_check, errors: want_errors)) }
        o << ""
      end
      unless regexes.empty?
        o << "use regex::Regex;"
        o << "use std::sync::LazyLock;"
        o << ""
        regexes.each do |r|
          o << "static #{r['id']}: LazyLock<Regex> = LazyLock::new(|| Regex::new(#{AxumDsl.rstr(r['pattern'])}).unwrap());"
        end
        o << ""
      end
      ir["items"].to_a.each do |code|
        o << "// injected Rust (rust_item): written by hand, not generated"
        o.concat(code.lines.map(&:chomp))
        o << ""
      end
      if ir["subprocs"].to_a.any? || ir["modules"].to_a.any? { |m| m["uses"] == "subprocess" }
        o << "// subprocess helper and wrappers (cmd_fn / script_fn): written by the compiler"
        o.concat(RUN_SUBPROCESS.lines.map(&:chomp))
        o << ""
        ir["subprocs"].to_a.each do |sp|
          mapped(o, ranges, sp, "subprocess `#{sp['name']}`") { o.concat(subproc_fn(sp)) }
          o << ""
        end
      end
      ir["binding_fns"].to_a.each do |b|
        o << "// binding function (see bindings/): written by the compiler"
        o.concat(binding_fn(b))
        o << ""
      end
      CompositeTypes::Opaque.types.reject { |t| t.fields.to_a.empty? }.each { |t| record_check(o, ranges, t) }
      unless ir["checked"].to_a.empty?
        o << "// overflow-checked integer arithmetic (only what this server uses): written by the compiler"
        o.concat(checked_int_lines(ir["checked"]))
      end
      { "str_to_i" => ["String#to_i", STR_TO_I], "str_to_int" => ["Integer(text, 10)", STR_TO_INT] }.each do |key, (what, rust)|
        next unless ir["helpers"].to_a.include?(key)

        o << "// #{what} (Ruby rules, i64 result): written by the compiler"
        o.concat(rust.lines.map(&:chomp))
        o << ""
      end
      if ir["html_escape"]
        # The escaper h(...) lowers to; raw(...) is the unescaped door and needs it not. Written by the
        # compiler, once per crate, only for a file whose bodies use h -- the way regex_dep is conditional.
        o << "// HTML escaping for h(...) (raw(...) is the unescaped door): written by the compiler"
        o.concat(HTML_ESCAPE.lines.map(&:chomp))
        o << ""
      end
      o.concat(Sanitize.items(ir))
      ir["user_helpers"].to_a.each do |h|
        mapped(o, ranges, h, "helper `#{h['name']}`") { o.concat(helper_fn(h)) }
        o << ""
      end
      o.concat([*settings_runtime(ir), ""]) if settings?(ir)
      database_items(o, ranges, ir) if ir["database"]
      o.concat([*Cookies.runtime_lines(ir), ""]) if ir["cookies"]
      o.concat(Sessions.items(ir))
      o.concat(Csrf.items(ir))
      o.concat([*rate_limit_runtime(ir), ""]) if layer?(ir, "rate_limit")
      if Sessions.currents?(ir)
        o.concat(Sessions.currents_lines(ir))
        ir["currents"].each do |c|
          mapped(o, ranges, c, "current `#{c["name"]}`") { o.concat(Sessions.current_fn(c)) }
          o << ""
        end
      end
      o.concat(files_runtime(ir))
      if error_needed?(ir, plan)
        # error_runtime writes the compiler's own 500 helper and the `error` filter's response; when the
        # filter has a line, the whole block is claimed for it (the compiler-written helper has none).
        if ir["error"] && ir["error"]["line"]
          mapped(o, ranges, ir["error"], "error filter") { o.concat(error_runtime(ir)) }
        else
          o.concat(error_runtime(ir))
        end
        o << ""
      end
      if ir["openapi"]
        o.concat(openapi_fns(ir))
        o << ""
      end
      plan["routes"].each_with_index do |entry, i|
        mapped(o, ranges, entry["route"], "route `#{entry['route']['method']} #{entry['route']['path']}`") do
          o.concat(route_fn(entry, "route_#{i + 1}"))
        end
        o << ""
      end
      ir["before"].to_a.each_with_index do |b, i|
        mapped(o, ranges, b, "before filter") { o.concat(before_fn(b, "before_#{i + 1}")) }
        o << ""
      end
      if ir["not_found"]
        mapped(o, ranges, ir["not_found"], "not_found filter") { o.concat(not_found_fn(ir["not_found"])) }
        o << ""
      end
      if forwarded?(ir)
        o << "// The request span of `use_layer :trace, forwarded: true`: written by the compiler"
        o.concat(CLIENT_SPAN.lines.map(&:chomp))
        o << ""
      end
      o << "// Resolves on ctrl-c or SIGTERM, so the server stops taking connections and drains: written by the compiler"
      o.concat(SHUTDOWN_SIGNAL.lines.map(&:chomp))
      o << ""
      o.concat(main_fn(ir, plan))
      o.concat(regex_test(regexes))
      ["#{o.join("\n")}\n", source_map(o, ranges, src)]
    end

    # Whether anything the emitted code runs can fail: a fallible body is what needs error_response, so
    # a service made only of bodies that cannot fail writes none of it (and would warn about it if it did).
    def error_needed?(ir, plan)
      plan["routes"].any? { |e| e["route"]["body"]["fallible"] } ||
        ir["before"].to_a.any? { |b| b["fallible"] } ||
        !!(ir["not_found"] && ir["not_found"]["fallible"])
    end

    # The handler-level error path: what a body that raised or overflowed answers with. The `error`
    # filter's response when there is one, and a plain 500 carrying the message when there is not. A
    # body cannot read the message yet (the reader gives the filter no argument for it), so the filter
    # cannot put it in the response; `let _ = message;` keeps its parameter from being unused.
    def error_runtime(ir)
      err = ir["error"]
      lines = []
      if err.nil? || err["fallible"]
        lines.concat(["fn internal_error(message: &str) -> ::axum::response::Response {",
                      "    let mut response = #{Body::INTO}(message.to_string());",
                      "    *response.status_mut() = ::axum::http::StatusCode::INTERNAL_SERVER_ERROR;",
                      "    response",
                      "}",
                      ""])
      end
      if err && !err["fallible"]
        lines.concat(["fn error_response(message: &str) -> ::axum::response::Response {",
                      "    let _ = message;",
                      *err["locals"].map { |l| "    #{l}" },
                      "    #{response_expr(err)}",
                      "}"])
      elsif err
        open, call = closure_wrap(err)
        lines.concat(["fn error_response(message: &str) -> ::axum::response::Response {",
                      "    let _ = message;",
                      "    match #{open}Result<::axum::response::Response, String> {",
                      *err["locals"].map { |l| "        #{l}" },
                      "        Ok(#{response_expr(err)})",
                      "    #{call} {",
                      "        Ok(response) => response,",
                      "        Err(inner) => internal_error(&inner),",
                      "    }",
                      "}"])
      else
        lines.concat(["fn error_response(message: &str) -> ::axum::response::Response {",
                      "    internal_error(message)",
                      "}"])
      end
      lines
    end

    # The Rust expression a body's value is, as the ::axum::response::Response a handler returns. A body
    # that ended in json/text/html/halt/redirect already is one (Body lowers those through IntoResponse);
    # one that ended in a string becomes a 200 text/plain response through IntoResponse, which is
    # Sinatra's rule for a body that ends in a string.
    # `status(...)`, `headers(...)` and the 400 default of an errors route, when the body is one that sets
    # them, are applied here, so every response a body produces carries them: the value the body ended in,
    # whatever built it, and the response a `before` filter passes on (see before_fn). The block is one
    # expression, so it fits where a handler returns its response directly.
    def response_expr(b)
      base = b["type"] == "response" ? b["expr"] : "#{Body::INTO}(#{b['expr']})"
      headers = b["headers"].to_a
      return base if b["status"].nil? && headers.empty? && b["etag"].nil? && !b["errors"] && !b["cookies"]

      # The etag value is a statement before the body's last expression, so it is computed before the
      # response value is built: a local the response moves is still there to borrow.
      lines = if b["etag"]
                ["{ let __etag = #{b['etag']};", "    let mut __stated = #{base};"]
              else
                ["{ let mut __stated = #{base};"]
              end
      if b["status"]
        # A body that set a status decides for itself, so a route that reads errors takes the 400 below
        # only when its body named no status.
        lines << "    *__stated.status_mut() = #{b['status']};"
      elsif b["errors"]
        # A route whose body reads errors[:field] keeps the 400 a violated check() always answered with,
        # applied here inside the body's own response expression, so a body that fails (`?`, an error
        # filter) keeps the 500 it answered with instead.
        lines << "    if !#{Body::ERRORS_MAP}.is_empty() { *__stated.status_mut() = ::axum::http::StatusCode::BAD_REQUEST; }"
      end
      lines.concat(header_inserts(headers, "__stated").map { |l| "    #{l}" })
      # A route body's `etag(value)`: the ETag rides on the final response, and a request whose
      # If-None-Match lists the value is answered 304 with no body. `__etag` was computed above, before the
      # response was built; only the comparison and the header happen here.
      if b["etag"]
        lines << "    if let Ok(__etag_value) = ::axum::http::HeaderValue::from_str(&__etag) {"
        lines << "        let __not_modified = __headers"
        lines << "            .get(::axum::http::header::IF_NONE_MATCH)"
        lines << "            .and_then(|value| value.to_str().ok())"
        lines << "            .map(|value| value.split(',').any(|tag| tag.trim() == __etag.as_str()))"
        lines << "            .unwrap_or(false);"
        lines << "        if __not_modified {"
        lines << "            __stated = ::axum::response::IntoResponse::into_response(::axum::http::StatusCode::NOT_MODIFIED);"
        lines << "        }"
        lines << "        __stated.headers_mut().insert(::axum::http::header::ETAG, __etag_value);"
        lines << "    }"
      end
      # the cookies the body set or deleted (set_cookie / delete_cookie): one Set-Cookie line each
      lines << "    axum_dsl_apply_cookies(&mut __stated, &__cookies);" if b["cookies"]
      lines << "    __stated }"
      lines.join("\n")
    end

    # The statements that put a body's `headers(...)` on a response. A name and a value were literals in the
    # DSL file, so both are static text here: inserting one cannot fail while the service runs (the reader
    # refused a name and a value no header may carry), and the name is lowercased, because http's HeaderName
    # wants a lowercase name.
    def header_inserts(headers, var)
      headers.map do |name, value|
        "#{var}.headers_mut().insert(::axum::http::HeaderName::from_static(#{AxumDsl.rstr(name.to_s.downcase)}), " \
          "::axum::http::HeaderValue::from_static(#{AxumDsl.rstr(value.to_s)}));"
      end
    end

    # Lines that bind `var` to the body's response. A body that can fail runs in a closure, so `?` (a
    # checked operation, to_i, a file read) has a Result to leave and the failure reaches error_response.
    # `mutable` binds `var` with `mut`, for the one caller that still has to change the response after
    # binding it (a filter's content type); the body's own `status` is applied by response_expr.
    def assign_response(b, var, mutable: false)
      binding = "let #{mutable ? 'mut ' : ''}#{var} = "
      return b["locals"] + ["#{binding}#{response_expr(b)};"] unless b["fallible"]

      open, call = closure_wrap(b)
      ["#{binding}match #{open}Result<::axum::response::Response, String> {",
       *b["locals"].map { |l| "    #{l}" },
       "    Ok(#{response_expr(b)})",
       "#{call} {",
       "    Ok(response) => response,",
       "    Err(message) => error_response(&message),",
       "};"]
    end

    # One route handler. The extractors come from the plan, in the order axum needs (only the last may
    # consume the body); a struct's check runs before the destructuring, because destructuring moves the
    # fields out of it. The body language records no per-field read set, so the destructuring binds every
    # field and the handler allows an unused one: the body language refuses unused locals and parameters
    # itself, so this cannot hide a mistake in the DSL file. A part marked "errors" is a route whose body
    # read errors[:field]: the check's messages are bound before the destructuring instead, and the body
    # decides what to answer with. response_expr applies the 400 the check's violations always answered
    # with, unless that body set a status of its own.
    def route_fn(entry, name)
      parts = entry["parts"]
      lines = []
      body = entry["route"]["body"]
      request = request_extractors(body)
      lines << "#[allow(unused_variables)]" unless parts.empty?
      lines << "async fn #{name}(#{(request + parts.map { |p| extractor_param(p) }).join(', ')}) -> ::axum::response::Response {"
      # What the body read of the request (body.rb: need): the peer address becomes the Option the body's code reads,
      # and a body that sets cookies keeps their Set-Cookie lines until the response is built (response_expr).
      lines << "    let __peer = Some(__connect);" if body["request"].to_a.include?("peer")
      lines << "    let mut __cookies: Vec<String> = Vec::new();" if body["cookies"]
      # A route whose body reads errors[:field] takes the check's messages into the body instead of the
      # 400 below; a route of any other kind writes exactly what it always wrote. The map is built before
      # the destructuring, which moves the struct the checks read.
      errors_parts = parts.select { |p| p["errors"] }
      lines.concat(errors_binding(errors_parts).map { |l| "    #{l}" }) unless errors_parts.empty?
      parts.each do |p|
        next unless p["check"] && !p["errors"]

        lines << "    if let Err(message) = #{p['binding']}.check() {"
        lines << "        return #{Body::INTO}((::axum::http::StatusCode::BAD_REQUEST, message));"
        lines << "    }"
      end
      parts.each do |p|
        lines << "    let #{p['struct']} { #{p['fields'].map { |f| f['name'] }.join(', ')} } = #{p['binding']};"
      end
      lines.concat(assign_response(entry["route"]["body"], "response").map { |l| "    #{l}" })
      lines << "    response"
      lines << "}"
      lines
    end

    # The check's messages, bound in the handler where the body reads them as errors[:field]. The match's
    # Ok arm is an empty map, so a body interpolates errors[:field] and gets "" on a request that passed
    # its checks; the Err arm carries one message per violated field. Body::ERRORS_MAP is the name the
    # body lowers to. A route whose parts arrive in more than one place merges what each part reported.
    def errors_binding(parts)
      calls = parts.map { |p| "#{p['binding']}.check_errors()" }
      empty = "std::collections::BTreeMap::new()"
      if calls.size == 1
        return ["let #{Body::ERRORS_MAP} = match #{calls[0]} {", "    Ok(()) => #{empty},",
                "    Err(errors) => errors,", "};"]
      end

      ["let mut #{Body::ERRORS_MAP} = #{empty};",
       *calls.map { |c| "#{Body::ERRORS_MAP}.extend(match #{c} { Ok(()) => #{empty}, Err(errors) => errors });" }]
    end

    # The extractors a body that reads the request needs, ahead of the params ones (the body extractor goes last):
    # the headers (cookie, user_agent, request_ip), the peer (request_ip, current) and the request's current cells.
    def request_extractors(body)
      want = body["request"].to_a
      out = []
      out << "__headers: ::axum::http::HeaderMap" if want.include?("headers")
      out << "::axum::extract::ConnectInfo(__connect): ::axum::extract::ConnectInfo<::std::net::SocketAddr>" if want.include?("peer")
      out << "::axum::Extension(__currents): ::axum::Extension<::std::sync::Arc<AxumDslCurrents>>" if want.include?("currents")
      out << "::axum::Extension(__csrf): ::axum::Extension<AxumDslCsrfToken>" if want.include?("csrf")
      out
    end

    def extractor_param(p)
      case p["source"]
      when "path" then "axum::extract::Path(#{p['binding']}): axum::extract::Path<#{p['struct']}>"
      when "query" then "axum::extract::Query(#{p['binding']}): axum::extract::Query<#{p['struct']}>"
      when "form" then "axum::extract::Form(#{p['binding']}): axum::extract::Form<#{p['struct']}>"
      else "axum::extract::Json(#{p['binding']}): axum::extract::Json<#{p['struct']}>"
      end
    end

    # A `before` filter, as middleware. A body that ends in a response helper answers the request itself
    # (a guard that halts); one that ends in a plain value does not stop the request, and the filter
    # passes it on. The body language has no "continue" value, so the shape of the last expression is
    # what decides, and `next.run` is the only thing a filter that continues does.
    def before_fn(b, name)
      lines = ["async fn #{name}(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {"]
      # What the body read of the request, taken before the request goes on to `next.run` (body.rb: need). The
      # headers are copied, so the request can still be moved into the next handler.
      want = b["request"].to_a
      lines << "    let __headers = request.headers().clone();" if want.include?("headers")
      lines << "    let __peer = request.extensions().get::<::axum::extract::ConnectInfo<::std::net::SocketAddr>>().map(|__c| __c.0);" if want.include?("peer")
      lines << "    let __currents = request.extensions().get::<::std::sync::Arc<AxumDslCurrents>>().cloned().unwrap_or_default();" if want.include?("currents")
      lines << "    let __csrf = request.extensions().get::<AxumDslCsrfToken>().cloned().unwrap_or_default();" if want.include?("csrf")
      if b["type"] == "response"
        # The body answers the request itself; a content type below still has to change the response.
        lines.concat(assign_response(b, "response", mutable: !b["content_type"].nil?).map { |l| "    #{l}" })
      else
        if b["fallible"]
          open, call = closure_wrap(b)
          lines << "    match #{open}Result<(), String> {"
          lines.concat(b["locals"].map { |l| "        #{l}" })
          lines << "        let _ = #{b['expr']};"
          lines << "        Ok(())"
          lines << "    #{call} {"
          lines << "        Ok(()) => {}"
          lines << "        Err(message) => return error_response(&message),"
          lines << "    }"
        else
          lines.concat(b["locals"].map { |l| "    #{l}" })
          lines << "    let _ = #{b['expr']};"
        end
        # The filter passes the request on: `mut` only when the content type, the status or the headers below set it.
        changes = b["content_type"] || b["status"] || !b["headers"].to_a.empty?
        lines << "    let #{changes ? 'mut ' : ''}response = next.run(request).await;"
      end
      if b["content_type"]
        lines << "    response.headers_mut().insert("
        lines << "        ::axum::http::header::CONTENT_TYPE,"
        lines << "        ::axum::http::HeaderValue::from_static(#{AxumDsl.rstr(content_type_value(b['content_type']))}),"
        lines << "    );"
      end
      # A `status(...)` in a filter that continues applies to the response that goes on to the route, and so
      # do the `headers(...)` below; a filter that answered the request itself already carries both, applied
      # by response_expr.
      lines << "    *response.status_mut() = #{b['status']};" if b["status"] && b["type"] != "response"
      # The headers of a filter that answered the request itself are already on its response (response_expr);
      # one that passes the request on puts them on what the next handler (a route, or a mounted file
      # service) answered with.
      lines.concat(header_inserts(b["headers"].to_a, "response").map { |l| "    #{l}" }) if b["type"] != "response"
      lines << "    response"
      lines << "}"
      lines
    end

    # What a request that matched no route answers with.
    def not_found_fn(b)
      lines = ["async fn not_found() -> ::axum::response::Response {"]
      lines.concat(assign_response(b, "response").map { |l| "    #{l}" })
      lines << "    response"
      lines << "}"
      lines
    end

    # The OpenAPI document of an `openapi` declaration, built by OpenApi at compile time and served as one
    # static string: a const and the handler main_fn routes GET at the declared path to.
    def openapi_fns(ir)
      [
        "// The OpenAPI document of this service (openapi): written by the compiler from the routes and params",
        "const OPENAPI_JSON: &str = #{AxumDsl.rstr(OpenApi.json(ir))};",
        "",
        "async fn openapi_json() -> impl axum::response::IntoResponse {",
        "    ([(axum::http::header::CONTENT_TYPE, \"application/json\")], OPENAPI_JSON)",
        "}"
      ]
    end

    # The header value a `content_type(...)` statement names. The reader validated the name against the
    # same table, which Body carries.
    def content_type_value(name) = Body::CONTENT_TYPES.fetch(name.to_sym)

    # The address the service listens on when the environment does not say: `set :bind` and `set :port`,
    # defaulting to Sinatra's own host and port (a service that never says `set :port` still starts
    # somewhere predictable). main_fn lets the environment variables BIND and PORT override both.
    def bind_default(ir) = ir["bind"] || "127.0.0.1"

    def port_default(ir) = ir["port"] || 4567

    # The statement that makes `listener`. By default it is tokio's TcpListener. `set :listener,
    # "tls::TlsListener"` calls `tls::TlsListener::bind((bind.as_str(), port)).await?` instead, so the type
    # (from a rust_file) has `async fn bind(addr: (&str, u16)) -> std::io::Result<Self>` and implements
    # axum::serve::Listener with Addr = SocketAddr. It is wrapped with ListenerExt::tap_io (a no-op
    # closure) because axum implements Connected<IncomingStream<..>> for SocketAddr only for TcpListener and
    # for TapIo<L, F> with L::Addr = SocketAddr; that is what keeps ConnectInfo<SocketAddr> working, which
    # `use_layer :trace, forwarded: true` reads. PORT, BIND and the graceful shutdown are unchanged.
    def listener_lines(ir)
      type = ir["listener"]
      return ["    let listener = tokio::net::TcpListener::bind((bind.as_str(), port)).await?;"] unless type

      ["    let listener = axum::serve::ListenerExt::tap_io(#{type}::bind((bind.as_str(), port)).await?, |_| {});"]
    end

    # The axum routing function for a verb. The reader accepts exactly these, so the name is the verb.
    def routing_fn(method) = "axum::routing::#{method}"

    def main_fn(ir, plan)
      # the settings are read before the first request can arrive; a server that cannot be configured does not start
      start = settings?(ir) ? ["    match load_settings() {",
                               "        Ok(loaded) => {",
                               "            let _ = SETTINGS.set(loaded);",
                               "        }",
                               "        Err(message) => {",
                               "            eprintln!(\"{message}\");",
                               "            std::process::exit(2);",
                               "        }",
                               "    }"] : []
      start.concat(Cookies.start_lines(ir)) # a key that is too short stops the server, like a setting that cannot load
      start.unshift(*subscriber_lines(ir)) if logging?(ir)
      # a `file` that is missing, or whose entries no longer match the build, stops the server before it serves
      unless ir["files"].to_a.empty?
        start += ["    if let Err(message) = check_files() {",
                  "        eprintln!(\"{message}\");",
                  "        std::process::exit(2);",
                  "    }"]
      end
      # the database is opened, migrated and checked before the first request can arrive, like the settings
      start += Db.backend(ir["database"]["adapter"]).start_lines if ir["database"]
      chain = ["axum::Router::new()"]
      plan["routes"].each_with_index do |entry, i|
        chain << ".route(#{AxumDsl.rstr(entry['route']['path'])}, #{routing_fn(entry['route']['method'])}(route_#{i + 1}))"
      end
      # One route per `serve_file`, and one service for each `static` mount: ServeDir nested at the mount
      # prefix, or the fallback when the prefix is "/" (axum refuses to nest at "/").
      ir["serve_files"].to_a.each do |f|
        chain << ".route(#{AxumDsl.rstr(f['path'])}, axum::routing::get_service(::tower_http::services::ServeFile::new(#{AxumDsl.rstr(f['from'])})))"
      end
      chain << ".route(#{AxumDsl.rstr(ir['openapi']['path'])}, axum::routing::get(openapi_json))" if ir["openapi"]
      ir["statics"].to_a.each do |s|
        service = "::tower_http::services::ServeDir::new(#{AxumDsl.rstr(s['dir'])}).append_index_html_on_directories(true)"
        chain << if s["prefix"] == "/"
                   ".fallback_service(#{service})"
                 else
                   ".nest_service(#{AxumDsl.rstr(s['prefix'])}, #{service})"
                 end
      end
      chain << ".fallback(not_found)" if ir["not_found"]

      ir["before"].to_a.each_index { |i| chain << ".layer(axum::middleware::from_fn(before_#{i + 1}))" }
      # The cells of `current` are made by the outermost filter layer, so a filter and its route read the same ones.
      chain << ".layer(axum::middleware::from_fn(axum_dsl_current_scope))" if Sessions.currents?(ir)
      # The use_layer middleware, in the emitter's fixed order (LAYER_ORDER), after every route and the
      # fallback, because axum's Router::layer only wraps what is already registered.
      LAYER_ORDER.each { |name| chain << ".layer(#{layer_expr(ir, name)})" if layer?(ir, name) }
      chain[-1] = "#{chain[-1]};"
      [
        "#[tokio::main]",
        "async fn main() -> anyhow::Result<()> {",
        *start,
        "    let router = #{chain.join("\n        ")}",
        # the environment wins over `set :port`/`set :bind`; a PORT that is not a port is refused like a
        # setting that cannot load, before anything listens
        "    let port = match std::env::var(\"PORT\") {",
        "        Ok(value) => match value.parse::<u16>() {",
        "            Ok(port) => port,",
        "            Err(_) => {",
        "                eprintln!(\"PORT must be a port number from 0 to 65535, got {value:?}\");",
        "                std::process::exit(2);",
        "            }",
        "        },",
        "        Err(_) => #{port_default(ir)},",
        "    };",
        "    let bind = std::env::var(\"BIND\").unwrap_or_else(|_| #{AxumDsl.rstr(bind_default(ir))}.to_string());",
        *listener_lines(ir),
        "    axum::serve(listener, router.into_make_service_with_connect_info::<std::net::SocketAddr>())",
        "        .with_graceful_shutdown(shutdown_signal())",
        "        .await?;",
        "    Ok(())",
        "}"
      ]
    end
  end
end

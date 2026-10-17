# frozen_string_literal: true

module AxumDsl
  # The compiler's own runtime for sessions (docs/sessions.md) beyond cookies (cookies.rb): random_token, request_ip,
  # user_agent, the built-in Bcrypt, the `current` values and the :fetch_metadata layer. Every piece is Rust written
  # here, emitted only when a body or a `use_layer` uses it, so a service that does not use a piece has none of it
  # (and no unused item for rustc to warn about). The emitter reaches this through `deps`, `items`, `currents_lines`
  # and `current_fn`.
  module Sessions
    # The base58 alphabet Rails' has_secure_token draws from (no 0, O, I or l), 24 characters from the system's
    # random source: rand's thread generator is a ChaCha generator seeded from the operating system.
    RANDOM_TOKEN = <<~'RS'
      fn axum_dsl_random_token() -> String {
          use ::rand::Rng;
          const ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
          let mut rng = ::rand::rng();
          (0..24)
              .map(|_| char::from(ALPHABET.get(rng.random_range(0..ALPHABET.len())).copied().unwrap_or(b'1')))
              .collect()
      }
    RS

    # request_ip: the peer's address; with `use_layer :trace, forwarded: true` the first X-Forwarded-For entry
    # first, which is the trust that layer already declares (see Emit::CLIENT_SPAN).
    REQUEST_IP_FORWARDED = <<~'RS'
      fn axum_dsl_request_ip(headers: &::axum::http::HeaderMap, peer: Option<::std::net::SocketAddr>) -> String {
          let forwarded = headers
              .get("x-forwarded-for")
              .and_then(|value| value.to_str().ok())
              .and_then(|value| value.split(',').next())
              .map(|entry| entry.trim().to_string())
              .filter(|entry| !entry.is_empty());
          forwarded
              .or_else(|| peer.map(|addr| addr.ip().to_string()))
              .unwrap_or_default()
      }
    RS

    REQUEST_IP_PEER = <<~'RS'
      fn axum_dsl_request_ip(_headers: &::axum::http::HeaderMap, peer: Option<::std::net::SocketAddr>) -> String {
          peer.map(|addr| addr.ip().to_string()).unwrap_or_default()
      }
    RS

    USER_AGENT = <<~'RS'
      fn axum_dsl_user_agent(headers: &::axum::http::HeaderMap) -> String {
          headers
              .get(::axum::http::header::USER_AGENT)
              .and_then(|value| value.to_str().ok())
              .unwrap_or_default()
              .to_string()
      }
    RS

    # bcrypt is CPU-heavy (cost 12 is Rails' default), so both run on tokio's blocking pool. A digest that does not
    # parse, or a task that failed, verifies as false: Bcrypt.verify never raises.
    BCRYPT_VERIFY = <<~'RS'
      async fn axum_dsl_bcrypt_verify(plain: String, digest: String) -> bool {
          ::tokio::task::spawn_blocking(move || ::bcrypt::verify(plain, &digest).unwrap_or(false))
              .await
              .unwrap_or(false)
      }
    RS

    BCRYPT_HASH = <<~'RS'
      async fn axum_dsl_bcrypt_hash(plain: String) -> Result<String, String> {
          ::tokio::task::spawn_blocking(move || ::bcrypt::hash(plain, 12).map_err(|e| format!("error: Bcrypt.hash failed: {e}")))
              .await
              .map_err(|e| format!("error: Bcrypt.hash failed: {e}"))?
      }
    RS

    # use_layer :fetch_metadata: a write (anything but GET, HEAD and OPTIONS) from a browser that says it comes from
    # another site is refused. A request without Sec-Fetch-Site (curl, a server) passes.
    FETCH_METADATA = <<~'RS'
      async fn axum_dsl_fetch_metadata(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          let method = request.method();
          let reads = *method == ::axum::http::Method::GET || *method == ::axum::http::Method::HEAD || *method == ::axum::http::Method::OPTIONS;
          let cross_site = matches!(
              request.headers().get("sec-fetch-site"),
              Some(site) if site.as_bytes() != b"same-origin" && site.as_bytes() != b"none"
          );
          if !reads && cross_site {
              let mut refused = ::axum::response::IntoResponse::into_response("cross-site request refused");
              *refused.status_mut() = ::axum::http::StatusCode::FORBIDDEN;
              return refused;
          }
          next.run(request).await
      }
    RS

    # The layer that gives each request its own set of `current` cells. It is the outermost of the filters, so a
    # filter and the route that follows it read the same cells.
    CURRENT_SCOPE = <<~'RS'
      async fn axum_dsl_current_scope(mut request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          request.extensions_mut().insert(::std::sync::Arc::new(AxumDslCurrents::default()));
          next.run(request).await
      }
    RS

    # The Rust type of a current's value, from the shape the reader resolved.
    SCALAR_RUST = { "i64" => "i64", "string" => "String", "f64" => "f64", "bool" => "bool" }.freeze

    module_function

    def builtin?(ir, name) = ir["builtins"].to_a.include?(name)

    def currents?(ir) = !ir["currents"].to_a.empty?

    def forwarded?(ir) = ir["layers"].to_a.any? { |l| l["name"] == "trace" && l["forwarded"] }

    # The Cargo.toml dependency lines, each led by a newline: rand for random_token, bcrypt for Bcrypt.
    def deps(ir)
      out = []
      out << "\nrand = \"0.9\"" if builtin?(ir, "random_token")
      out << "\nbcrypt = \"0.17\"" if builtin?(ir, "bcrypt_verify") || builtin?(ir, "bcrypt_hash")
      out.join
    end

    # The tokio features beyond the crate's own: `sync` for the OnceCell a `current` is held in.
    def tokio_features(ir) = currents?(ir) ? ", \"sync\"" : ""

    def lines(text) = text.lines.map(&:chomp)

    # The runtime functions the file's builtins and layers need, each followed by a blank line.
    def items(ir)
      out = []
      add = ->(text) { out.concat(lines(text)) << "" }
      add.call(RANDOM_TOKEN) if builtin?(ir, "random_token")
      add.call(forwarded?(ir) ? REQUEST_IP_FORWARDED : REQUEST_IP_PEER) if builtin?(ir, "request_ip")
      add.call(USER_AGENT) if builtin?(ir, "user_agent")
      add.call(BCRYPT_VERIFY) if builtin?(ir, "bcrypt_verify")
      add.call(BCRYPT_HASH) if builtin?(ir, "bcrypt_hash")
      add.call(FETCH_METADATA) if ir["layers"].to_a.any? { |l| l["name"] == "fetch_metadata" }
      out.empty? ? out : ["// sessions runtime (random_token, request_ip, user_agent, Bcrypt, use_layer :fetch_metadata): written by the compiler", *out]
    end

    def current_rust(c)
      case c["shape"]
      when "list" then "Vec<#{c['record']}>"
      when "one" then "Option<#{c['record']}>"
      else c["nilable"] ? "Option<#{SCALAR_RUST.fetch(c['type'])}>" : SCALAR_RUST.fetch(c["type"])
      end
    end

    # The per-request cells, one OnceCell per `current`, and the layer that makes a fresh set for each request.
    # A request holds it in its extensions as an Arc, so a `before` filter and the route read the same one.
    def currents_lines(ir)
      cells = ir["currents"].map { |c| "    #{c['name']}: ::tokio::sync::OnceCell<#{current_rust(c)}>," }
      ["// the per-request values of `current`: each is computed on its first read and kept for the request: written by the compiler",
       "#[derive(Default)]",
       "struct AxumDslCurrents {",
       *cells,
       "}",
       "",
       *lines(CURRENT_SCOPE),
       ""]
    end

    # One current's function: its block, run by the first read. `?` and `return` leave it with the error the
    # reading body then fails with.
    def current_fn(c)
      body = c["body"]
      ["async fn axum_dsl_current_#{c['name']}(__headers: &::axum::http::HeaderMap, __peer: Option<::std::net::SocketAddr>, __currents: &AxumDslCurrents) -> Result<#{current_rust(c)}, String> {",
       *body["locals"].map { |l| "    #{l}" },
       "    Ok(#{body['expr']})",
       "}"]
    end
  end
end

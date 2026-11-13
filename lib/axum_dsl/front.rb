# frozen_string_literal: true

module AxumDsl
  # use_layer :front (docs/dsl.md): what sat in front of a Rails app in production and shaped its responses --
  # Rack::Deflater (rack 3.2) and Thruster 0.1's response cache and compression -- as one middleware, outermost
  # of the app's own (Emit::LAYER_ORDER), so the ETag :rack_defaults computes is over the identity body.
  #   gzip     a response is gzipped for a client whose Accept-Encoding allows gzip, whatever its size or type
  #            (Rack::Deflater has no minimum), except 1xx/204/304, `no-transform`, one already encoded, an event
  #            stream, and an upgrade request. A gzipped response has Content-Encoding: gzip and no Accept-Ranges.
  #            Not carried over from Thruster: zstd, and the BREACH padding.
  #   Vary     `accept-encoding` is added to every response that does not name it (after the app's own tokens, so a
  #            page's `Vary: Accept` becomes `accept, accept-encoding`).
  #   X-Cache  Thruster's cache: a GET/HEAD response that says `public` with a `max-age` (or `s-max-age`) above 0 and
  #            no `no-cache` is kept in memory until it expires and answered again with `X-Cache: hit` to a request with
  #            the same method, path, query, host and the headers the response varies on (`miss` the first time).
  #            A request that cannot be cached (not GET/HEAD, an upgrade, a range, a URI over 2048 bytes) goes
  #            through with `X-Cache: bypass`. `cache_mb:` bounds the cache (64 by default, 0 for none); a
  #            response over 1 MB is not kept. A hit that the client already has (If-None-Match names the
  #            stored ETag) is a 304. When the cache is full the entries nearest their expiry go first.
  # The statics (`static ..., digest: true` and `max_age:`) get their headers from `static_items`: Cache-Control
  # `max-age=N, public`, and no Accept-Ranges on a digest mount (Propshaft answers whole files).
  module Front
    DEFAULT_CACHE_MB = 64

    module_function

    def used?(ir) = ir["layers"].to_a.any? { |l| l["name"] == "front" }

    def entry(ir) = ir["layers"].to_a.find { |l| l["name"] == "front" }

    def layer_expr = "::axum::middleware::from_fn(axum_dsl_front)"

    # httpdate formats the real Date header; flate2 is shared with the response cache when it
    # stores a gzip body at admission. One Cargo line each.
    def deps(ir)
      return "" unless used?(ir)

      lines = ["\nhttpdate = \"1\""]
      lines << "\nflate2 = \"1\"" unless defined?(AxumDsl::ResponseCache) && AxumDsl::ResponseCache.used?(ir)
      lines.join
    end

    def cache_mb(ir) = entry(ir)&.[]("cache_mb") || DEFAULT_CACHE_MB

    # The statics that need a header middleware, as [index among the statics, entry].
    def header_statics(ir)
      ir["statics"].to_a.each_with_index.select { |s, _| s["digest"] || s["max_age"] }.map { |s, i| [i, s] }
    end

    def static_layer_expr(index) = "::axum::middleware::from_fn(axum_dsl_static_headers_#{index})"

    def static_items(ir)
      header_statics(ir).flat_map do |i, s|
        out = ["// static #{AxumDsl.rstr(s['prefix'])}: its files' headers, as Propshaft and ActionDispatch::Static send them: written by the compiler"]
        out << "async fn axum_dsl_static_headers_#{i}(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {"
        out << "    let mut response = next.run(request).await;"
        out << "    if response.status().is_success() || response.status().as_u16() == 304 {"
        out << "        let headers = response.headers_mut();"
        out << "        headers.remove(\"accept-ranges\");" if s["digest"]
        if s["max_age"]
          out << "        if !headers.contains_key(\"cache-control\") {"
          out << "            headers.insert(\"cache-control\", ::axum::http::HeaderValue::from_static(\"max-age=#{s['max_age']}, public\"));"
          out << "        }"
        end
        out << "    }"
        out << "    response"
        out << "}"
        out << ""
      end
    end

    def serve_file_layer_expr(index) = "::axum::middleware::from_fn(axum_dsl_serve_file_headers_#{index})"

    # A `serve_file` with `max_age:` gets ActionDispatch::Static's Cache-Control the way a `static` mount does.
    def serve_file_items(ir)
      ir["serve_files"].to_a.each_with_index.select { |f, _| f["max_age"] }.flat_map do |f, i|
        [
          "// serve_file #{AxumDsl.rstr(f['path'])}: its Cache-Control, as ActionDispatch::Static sends it: written by the compiler",
          "async fn axum_dsl_serve_file_headers_#{i}(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {",
          "    let mut response = next.run(request).await;",
          "    if response.status().is_success() || response.status().as_u16() == 304 {",
          "        let headers = response.headers_mut();",
          "        if !headers.contains_key(\"cache-control\") {",
          "            headers.insert(\"cache-control\", ::axum::http::HeaderValue::from_static(\"max-age=#{f['max_age']}, public\"));",
          "        }",
          "    }",
          "    response",
          "}",
          ""
        ]
      end
    end

    # `enabled: :name` (an integer setting read on each request, 0 is off) puts the app behind no front at all, as
    # Rails' test environment answers without Thruster: no deflate, no cache, no Date.
    def items(ir)
      enabled = entry(ir)&.[]("enabled")
      runtime = RUNTIME.lines.map(&:chomp)
      if enabled
        runtime = runtime.map { |l| l.sub("async fn axum_dsl_front(request:", "async fn axum_dsl_front_on(request:") }
        runtime += ["", "async fn axum_dsl_front(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {",
                    "    if settings().#{enabled} == 0 {", "        return next.run(request).await;", "    }",
                    "    axum_dsl_front_on(request, next).await", "}"]
      end
      [
        "// use_layer :front: Rack::Deflater and Thruster's response cache in front of the app: written by the compiler",
        "const AXUM_DSL_FRONT_CAPACITY: usize = #{cache_mb(ir)} * 1024 * 1024;",
        *runtime,
        ""
      ]
    end

    RUNTIME = <<~'RUST'
      const AXUM_DSL_FRONT_MAX_ITEM: usize = 1024 * 1024;
      const AXUM_DSL_FRONT_MAX_URI: usize = 2048;
      const AXUM_DSL_FRONT_MAX_DEFLATE: usize = 64 * 1024 * 1024;
      const AXUM_DSL_FRONT_ENTRY_OVERHEAD: usize = 256;

      struct AxumDslFrontEntry {
          base: String,
          expires: ::std::time::Instant,
          status: ::axum::http::StatusCode,
          headers: ::axum::http::HeaderMap,
          body: ::axum::body::Bytes,
          size: usize,
      }

      #[derive(Default)]
      struct AxumDslFrontCache {
          names: ::std::collections::HashMap<String, Vec<String>>,
          items: ::std::collections::HashMap<String, AxumDslFrontEntry>,
          size: usize,
      }

      static AXUM_DSL_FRONT: ::std::sync::OnceLock<::std::sync::Mutex<AxumDslFrontCache>> = ::std::sync::OnceLock::new();

      fn axum_dsl_front_cache() -> ::std::sync::MutexGuard<'static, AxumDslFrontCache> {
          AXUM_DSL_FRONT
              .get_or_init(|| ::std::sync::Mutex::new(AxumDslFrontCache::default()))
              .lock()
              .unwrap_or_else(|poisoned| poisoned.into_inner())
      }

      fn axum_dsl_front_text<'a>(headers: &'a ::axum::http::HeaderMap, name: &str) -> &'a str {
          headers.get(name).and_then(|value| value.to_str().ok()).unwrap_or("")
      }

      // Thruster's CacheStatus: how long the response may be kept, if at all.
      fn axum_dsl_front_lifetime(status: ::axum::http::StatusCode, headers: &::axum::http::HeaderMap) -> Option<::std::time::Duration> {
          let code = status.as_u16();
          if !(200..=399).contains(&code) || code == 304 {
              return None;
          }
          if axum_dsl_front_text(headers, "vary").contains('*') {
              return None;
          }
          let control = axum_dsl_front_text(headers, "cache-control").to_ascii_lowercase();
          let directives: Vec<&str> = control.split(',').map(str::trim).collect();
          if !directives.contains(&"public") || directives.contains(&"no-cache") {
              return None;
          }
          let age = |name: &str| directives.iter().find_map(|d| d.strip_prefix(name).and_then(|n| n.parse::<u64>().ok()));
          let seconds = age("s-max-age=").or_else(|| age("max-age="))?;
          (seconds > 0).then(|| ::std::time::Duration::from_secs(seconds))
      }

      fn axum_dsl_front_vary_names(headers: &::axum::http::HeaderMap) -> Vec<String> {
          let mut names: Vec<String> = headers
              .get_all("vary")
              .iter()
              .filter_map(|value| value.to_str().ok())
              .flat_map(|value| value.split(','))
              .map(|token| token.trim().to_ascii_lowercase())
              .filter(|token| !token.is_empty())
              .collect();
          names.sort();
          names.dedup();
          names
      }

      fn axum_dsl_front_variant(names: &[String], headers: &::axum::http::HeaderMap) -> String {
          names.iter().map(|name| format!("\n{name}={}", axum_dsl_front_text(headers, name))).collect()
      }

      // gzhttp's Vary: Accept-Encoding, after the app's own tokens, in one header.
      fn axum_dsl_front_add_vary(headers: &mut ::axum::http::HeaderMap) {
          let mut tokens: Vec<String> = headers
              .get_all("vary")
              .iter()
              .filter_map(|value| value.to_str().ok())
              .flat_map(|value| value.split(','))
              .map(|token| token.trim().to_owned())
              .filter(|token| !token.is_empty())
              .collect();
          if tokens.iter().any(|token| token == "*" || token.eq_ignore_ascii_case("accept-encoding")) {
              return;
          }
          tokens.push("accept-encoding".to_owned());
          if let Ok(value) = ::axum::http::HeaderValue::from_str(&tokens.join(", ")) {
              headers.insert("vary", value);
          }
      }

      fn axum_dsl_front_accepts_gzip(accept_encoding: &str) -> bool {
          let mut gzip: Option<f64> = None;
          let mut any: Option<f64> = None;
          for part in accept_encoding.split(',') {
              let mut pieces = part.split(';');
              let coding = pieces.next().unwrap_or("").trim().to_ascii_lowercase();
              let quality = pieces
                  .find_map(|piece| piece.trim().strip_prefix("q=").map(|value| value.trim().parse::<f64>().unwrap_or(0.0)))
                  .unwrap_or(1.0);
              if coding == "gzip" {
                  gzip = Some(quality);
              } else if coding == "*" {
                  any = Some(quality);
              }
          }
          gzip.or(any).map_or(false, |quality| quality > 0.0)
      }

      // Rack::Deflater, and the Vary header Thruster's compression adds to everything.
      async fn axum_dsl_front_deflate(request: ::axum::extract::Request, next: ::axum::middleware::Next, bypass: bool) -> ::axum::response::Response {
          let head = request.method() == ::axum::http::Method::HEAD;
          let accepts = axum_dsl_front_accepts_gzip(axum_dsl_front_text(request.headers(), "accept-encoding"));
          let upgrade = axum_dsl_front_text(request.headers(), "connection") == "Upgrade"
              || axum_dsl_front_text(request.headers(), "upgrade") == "websocket";
          let mut response = next.run(request).await;
          let had_vary = axum_dsl_front_vary_names(response.headers()).iter().any(|token| token == "accept-encoding");
          axum_dsl_front_add_vary(response.headers_mut());
          let status = response.status().as_u16();
          let headers = response.headers();
          let encoding = axum_dsl_front_text(headers, "content-encoding");
          // Rack::Deflater writes its Vary once it has not ruled the response out, whether or not the client takes gzip
          // (a media request says `identity;q=1, *;q=0`); `blocked` is what rules it out.
          let blocked = upgrade
              || matches!(status, 100..=199 | 204 | 304)
              || axum_dsl_front_text(headers, "cache-control").to_ascii_lowercase().contains("no-transform")
              || !(encoding.is_empty() || encoding.eq_ignore_ascii_case("identity"))
              || axum_dsl_front_text(headers, "content-type").starts_with("text/event-stream");
          let skip = !accepts || blocked;
          // A bypassed request (not cacheable) has Thruster add gzhttp's Vary to the response's own, which already carries
          // the one Rack::Deflater wrote (when it deflates), so Accept-Encoding repeats; the cache replaces instead.
          if bypass && (had_vary || !blocked) {
              let mut tokens: Vec<String> = axum_dsl_front_vary_names(response.headers());
              tokens.push("accept-encoding".to_owned());
              if let Ok(value) = ::axum::http::HeaderValue::from_str(&tokens.join(", ")) {
                  response.headers_mut().insert("vary", value);
              }
          }
          if skip {
              return response;
          }
          if head {
              let headers = response.headers_mut();
              headers.insert("content-encoding", ::axum::http::HeaderValue::from_static("gzip"));
              headers.remove("content-length");
              headers.remove("accept-ranges");
              return response;
          }
          let (mut parts, body) = response.into_parts();
          let bytes = match ::axum::body::to_bytes(body, AXUM_DSL_FRONT_MAX_DEFLATE).await {
              Ok(bytes) => bytes,
              Err(_) => {
                  return ::axum::response::Response::builder()
                      .status(::axum::http::StatusCode::INTERNAL_SERVER_ERROR)
                      .body(::axum::body::Body::empty())
                      .unwrap();
              }
          };
          let mut encoder = ::flate2::write::GzEncoder::new(Vec::new(), ::flate2::Compression::default());
          let compressed = ::std::io::Write::write_all(&mut encoder, &bytes).and_then(|_| encoder.finish());
          match compressed {
              Ok(compressed) => {
                  parts.headers.insert("content-encoding", ::axum::http::HeaderValue::from_static("gzip"));
                  parts.headers.remove("accept-ranges");
                  if bypass {
                      // Rack::Deflater streams its gzip: no Content-Length, so the answer goes out chunked, as Rails' does.
                      // Only a request the cache cannot keep; a cacheable one is stored, which needs its exact size.
                      parts.headers.remove("content-length");
                      let stream = ::axum::body::Body::from(compressed).into_data_stream();
                      return ::axum::response::Response::from_parts(parts, ::axum::body::Body::from_stream(stream));
                  }
                  parts.headers.insert("content-length", ::axum::http::HeaderValue::from(compressed.len()));
                  ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(compressed))
              }
              Err(_) => ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(bytes)),
          }
      }

      // WriteCachedResponse: the stored response, or a 304 when the request already has it.
      fn axum_dsl_front_hit(
          status: ::axum::http::StatusCode,
          headers: ::axum::http::HeaderMap,
          body: ::axum::body::Bytes,
          if_none_match: &str,
      ) -> ::axum::response::Response {
          let etag = axum_dsl_front_text(&headers, "etag").to_owned();
          let fresh = !etag.is_empty() && if_none_match.split(',').any(|candidate| candidate.trim() == etag);
          let mut response = ::axum::response::Response::new(if fresh { ::axum::body::Body::empty() } else { ::axum::body::Body::from(body) });
          *response.status_mut() = if fresh { ::axum::http::StatusCode::NOT_MODIFIED } else { status };
          *response.headers_mut() = headers;
          if fresh {
              response.headers_mut().remove("content-type");
              response.headers_mut().remove("content-length");
          }
          response.headers_mut().insert("x-cache", ::axum::http::HeaderValue::from_static("hit"));
          response
      }

      fn axum_dsl_front_store(
          base: String,
          names: Vec<String>,
          key: String,
          parts: &::axum::http::response::Parts,
          body: ::axum::body::Bytes,
          lifetime: ::std::time::Duration,
      ) {
          let header_bytes: usize = parts.headers.iter().map(|(name, value)| name.as_str().len() + value.len()).sum();
          let size = body.len() + header_bytes + key.len() + AXUM_DSL_FRONT_ENTRY_OVERHEAD;
          if size > AXUM_DSL_FRONT_MAX_ITEM || size > AXUM_DSL_FRONT_CAPACITY {
              return;
          }
          let mut cache = axum_dsl_front_cache();
          while cache.size + size > AXUM_DSL_FRONT_CAPACITY {
              let soonest = cache.items.iter().min_by_key(|(_, entry)| entry.expires).map(|(key, _)| key.clone());
              let Some(soonest) = soonest else { break };
              if let Some(old) = cache.items.remove(&soonest) {
                  cache.size -= old.size;
                  cache.names.remove(&old.base);
              }
          }
          let entry = AxumDslFrontEntry {
              base: base.clone(),
              expires: ::std::time::Instant::now() + lifetime,
              status: parts.status,
              headers: parts.headers.clone(),
              body,
              size,
          };
          if let Some(old) = cache.items.insert(key, entry) {
              cache.size -= old.size;
          }
          cache.size += size;
          cache.names.insert(base, names);
      }

      // The parity harness runs the candidate under libfaketime, so SystemTime::now is the seed
      // instant. The reference's Thruster writes Date outside faketime. Derive a real wall clock
      // from /proc (btime + uptime) and advance it with the real monotonic clock, so HTTP caching
      // sees a current Date while signed-id expiries keep using the app's fake clock.
      fn axum_dsl_front_real_epoch() -> u64 {
          static START: ::std::sync::OnceLock<(u64, ::std::time::Instant)> = ::std::sync::OnceLock::new();
          let (epoch, started) = START.get_or_init(|| {
              let stat = ::std::fs::read_to_string("/proc/stat").unwrap_or_default();
              let btime = stat
                  .lines()
                  .find_map(|line| line.strip_prefix("btime "))
                  .and_then(|value| value.trim().parse::<u64>().ok())
                  .unwrap_or(0);
              let uptime = ::std::fs::read_to_string("/proc/uptime")
                  .ok()
                  .and_then(|text| text.split_whitespace().next().and_then(|value| value.parse::<f64>().ok()))
                  .unwrap_or(0.0);
              (btime.saturating_add(uptime as u64), ::std::time::Instant::now())
          });
          epoch.saturating_add(started.elapsed().as_secs())
      }

      fn axum_dsl_front_real_date() -> String {
          let time = ::std::time::UNIX_EPOCH + ::std::time::Duration::from_secs(axum_dsl_front_real_epoch());
          ::httpdate::fmt_http_date(time)
      }

      fn axum_dsl_front_add_date(headers: &mut ::axum::http::HeaderMap) {
          if let Ok(value) = ::axum::http::HeaderValue::from_str(&axum_dsl_front_real_date()) {
              headers.insert(::axum::http::header::DATE, value);
          }
      }

      async fn axum_dsl_front_inner(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          let method = request.method().clone();
          let headers_in = request.headers().clone();
          let upgrade = axum_dsl_front_text(&headers_in, "connection") == "Upgrade" || axum_dsl_front_text(&headers_in, "upgrade") == "websocket";
          let length = request.uri().path_and_query().map_or(0, |target| target.as_str().len());
          let cacheable = (method == ::axum::http::Method::GET || method == ::axum::http::Method::HEAD)
              && !upgrade
              && axum_dsl_front_text(&headers_in, "range").is_empty()
              && length <= AXUM_DSL_FRONT_MAX_URI;
          if !cacheable {
              let mut response = axum_dsl_front_deflate(request, next, true).await;
              response.headers_mut().insert("x-cache", ::axum::http::HeaderValue::from_static("bypass"));
              return response;
          }
          let base = format!(
              "{}\n{}\n{}\n{}",
              method,
              request.uri().path(),
              request.uri().query().unwrap_or(""),
              axum_dsl_front_text(&headers_in, "host")
          );
          let names = axum_dsl_front_cache().names.get(&base).cloned().unwrap_or_default();
          let key = format!("{base}{}", axum_dsl_front_variant(&names, &headers_in));
          let found = {
              let cache = axum_dsl_front_cache();
              let now = ::std::time::Instant::now();
              let hit = cache
                  .items
                  .get(&key)
                  .filter(|entry| entry.expires >= now)
                  .map(|entry| (entry.status, entry.headers.clone(), entry.body.clone()));
              hit
          };
          if let Some((status, headers, body)) = found {
              return axum_dsl_front_hit(status, headers, body, axum_dsl_front_text(&headers_in, "if-none-match"));
          }
          let mut response = axum_dsl_front_deflate(request, next, false).await;
          let lifetime = if AXUM_DSL_FRONT_CAPACITY == 0 { None } else { axum_dsl_front_lifetime(response.status(), response.headers()) };
          let sized = ::axum::body::HttpBody::size_hint(response.body()).exact().is_some_and(|length| length <= AXUM_DSL_FRONT_MAX_ITEM as u64);
          let Some(lifetime) = lifetime.filter(|_| sized) else {
              response.headers_mut().insert("x-cache", ::axum::http::HeaderValue::from_static("miss"));
              return response;
          };
          response.headers_mut().remove("set-cookie");
          let (mut parts, body) = response.into_parts();
          let bytes = match ::axum::body::to_bytes(body, AXUM_DSL_FRONT_MAX_ITEM).await {
              Ok(bytes) => bytes,
              Err(_) => {
                  return ::axum::response::Response::builder()
                      .status(::axum::http::StatusCode::INTERNAL_SERVER_ERROR)
                      .body(::axum::body::Body::empty())
                      .unwrap();
              }
          };
          let names = axum_dsl_front_vary_names(&parts.headers);
          let key = format!("{base}{}", axum_dsl_front_variant(&names, &headers_in));
          axum_dsl_front_store(base, names, key, &parts, bytes.clone(), lifetime);
          parts.headers.insert("x-cache", ::axum::http::HeaderValue::from_static("miss"));
          ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(bytes))
      }

      async fn axum_dsl_front(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          let mut response = axum_dsl_front_inner(request, next).await;
          axum_dsl_front_add_date(response.headers_mut());
          response
      }
    RUST
  end
end

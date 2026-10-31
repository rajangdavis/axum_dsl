# frozen_string_literal: true

module AxumDsl
  # `get "/x", cache: :private do ... end` (WAVE-PLAN AP1): the whole response of a GET route is kept in memory and
  # answers a repeat of the same request without running the route body. The reference is
  # once-campfire-rust/crates/campfire/src/response_cache.rs, whose rules are kept:
  #
  # * the `before` filters (and the `current ... required:` checks they make) run on every request, hit or miss,
  #   because the lookup is the first thing the route's handler does, after every filter layer has passed;
  # * the generation is an atomic: this process's own commits bump it from db_after_write, and a thread owning a
  #   second, read-only SQLite connection polls `PRAGMA data_version` every millisecond and bumps it for the
  #   commits of other processes. Each change is a new generation and drops every entry. (Before, one global
  #   lock and two PRAGMA calls per request were the ceiling of every hit.) So a commit by another process can
  #   be served stale for up to about 1 ms; an own commit is never missed, it is counted before its write
  #   returns. The generation is read by a layer outside the filters, so a commit that lands while a filter or
  #   the body runs makes the response unreachable: it is checked again at lookup and at admission;
  # * the key is a SHA-256 over length-prefixed fields: the generation, the route, the full URI and every request
  #   header (Cookie among them, so an entry belongs to one session) except the validators and tracing ones;
  # * only a 200 without `no-store`/`no-transform`, whose body is in memory and at most 1 MiB, is stored; the
  #   `Set-Cookie` and `Date` headers are not, and an entry lives 15 seconds because a page can carry the time.
  #
  # The size is `setting :response_cache_mb` (a `type: :i64` setting) when the file declares one, else 64 MB; 0
  # turns the cache off. The reader (Reader#check_route_cache) has already refused a route whose body does
  # something a commit does not explain. With `use_layer :front`, a gzip client's body is compressed at
  # admission and stored compressed; the key includes Accept-Encoding, so variants stay apart. std, sha2 and
  # flate2; rusqlite is the database backend's.
  module ResponseCache
    DEFAULT_MB = 64
    SETTING = "response_cache_mb"

    module_function

    def routes(ir) = ir["routes"].to_a.select { |r| r["cache"] }

    def used?(ir) = !!ir["database"] && !routes(ir).empty?

    # The Cargo.toml dependency line, led by a newline like the others. flate2 is also needed here because a
    # gzip client's cached body is compressed at admission (when :front is in use).
    def deps(ir) = used?(ir) ? "\nsha2 = \"0.10\"\nflate2 = \"1\"" : ""

    # The extractors a cached route's handler takes ahead of its params: what the lookup keys on.
    def extractors
      ["::axum::Extension(__cache_ticket): ::axum::Extension<AxumDslCacheTicket>",
       "__cache_method: ::axum::http::Method",
       "__cache_uri: ::axum::http::Uri",
       "__cache_headers: ::axum::http::HeaderMap"]
    end

    # The first statement of a cached route's handler: a hit is answered here, a miss goes on with what admission needs.
    def lookup_lines(path)
      ["    let __cache_admit = match axum_dsl_cache_lookup(#{AxumDsl.rstr(path)}, __cache_ticket.0, &__cache_method, &__cache_uri, &__cache_headers) {",
       "        AxumDslCacheOutcome::Hit(cached) => return cached,",
       "        AxumDslCacheOutcome::Miss(admit) => admit,",
       "    };"]
    end

    # The call that ends a cached route's handler.
    def admit_line = "    axum_dsl_cache_admit(__cache_admit, response).await"

    # The statement db_open ends with: open the observer on the same file, sized from the setting when there is one.
    def open_line(ir)
      megabytes = ir["settings"].to_a.any? { |s| s["name"].to_s == SETTING } ? "settings().#{SETTING}" : DEFAULT_MB.to_s
      "    axum_dsl_cache_open(&path, #{megabytes})?;"
    end

    # The layer that reads the generation, outside the `before` layers (Emit#main_fn puts it there).
    def layer_expr = "::axum::middleware::from_fn(axum_dsl_cache_begin)"

    def items(ir)
      return [] unless used?(ir)

      list = routes(ir).map { |r| AxumDsl.rstr(r["path"]) }.uniq.join(", ")
      ["// the response cache of `cache: :private` routes (after once-campfire-rust/crates/campfire/src/response_cache.rs): written by the compiler",
       *RUNTIME.sub("__ROUTES__", list).sub("__GZIP__", AxumDsl::Front.used?(ir) ? "true" : "false").lines.map(&:chomp), ""]
    end

    RUNTIME = <<~'RS'
      const AXUM_DSL_CACHE_ROUTES: &[&str] = &[__ROUTES__];
      // When :front is in use, admission stores a gzip client's body already compressed; a hit then skips the
      // deflater. The key includes Accept-Encoding, so identity and gzip entries never share a body.
      const AXUM_DSL_CACHE_GZIP: bool = __GZIP__;
      const AXUM_DSL_CACHE_MAX_BODY: usize = 1024 * 1024;
      const AXUM_DSL_CACHE_MAX_KEY_INPUT: usize = 8192;
      // A page can carry the time (relative dates), so an entry expires even when nothing was committed.
      const AXUM_DSL_CACHE_TTL: ::std::time::Duration = ::std::time::Duration::from_secs(15);

      struct AxumDslCacheEntry {
          status: ::axum::http::StatusCode,
          headers: ::axum::http::HeaderMap,
          body: ::axum::body::Bytes,
          expires: ::std::time::Instant,
          size: usize,
      }

      // The entries of one generation. `generation` is the one they belong to: the first writer to see the
      // atomic ahead of it clears the map.
      struct AxumDslCacheEntries {
          generation: u64,
          entries: ::std::collections::HashMap<[u8; 32], ::std::sync::Arc<AxumDslCacheEntry>>,
          order: ::std::collections::VecDeque<[u8; 32]>,
          bytes: usize,
      }

      // One global lock holding the observer connection and running two `PRAGMA data_version` calls per hit was the
      // ceiling of every cached route. The generation is now an atomic read without a lock: this process's own
      // commits bump it (axum_dsl_cache_note_commit, from db_after_write, before the write returns) and a thread
      // that owns the read-only observer connection polls data_version every millisecond for the commits of other
      // processes, so one of those can be served stale for up to about 1 ms. Hits take only the read lock.
      struct AxumDslCache {
          generation: ::std::sync::atomic::AtomicU64,
          entries: ::std::sync::RwLock<AxumDslCacheEntries>,
          capacity: usize,
      }

      static AXUM_DSL_CACHE: ::std::sync::OnceLock<AxumDslCache> = ::std::sync::OnceLock::new();

      // Called at the end of db_open. A size of 0 (or less) leaves the cache unset, which bypasses it everywhere.
      fn axum_dsl_cache_open(path: &str, megabytes: i64) -> Result<(), String> {
          if megabytes <= 0 {
              return Ok(());
          }
          let db = rusqlite::Connection::open_with_flags(
              path,
              rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
          )
          .map_err(|e| format!("database {path}: cannot open the response cache observer: {e}"))?;
          db.busy_timeout(::std::time::Duration::from_millis(50))
              .map_err(|e| format!("database {path}: response cache observer: {e}"))?;
          let data_version: i64 = db
              .query_row("PRAGMA data_version", [], |row| row.get(0))
              .map_err(|e| format!("database {path}: response cache observer: {e}"))?;
          let capacity = (megabytes as usize).saturating_mul(1024 * 1024);
          let entries = AxumDslCacheEntries {
              generation: 0,
              entries: ::std::collections::HashMap::new(),
              order: ::std::collections::VecDeque::new(),
              bytes: 0,
          };
          let cache = AxumDslCache { generation: ::std::sync::atomic::AtomicU64::new(0), entries: ::std::sync::RwLock::new(entries), capacity };
          if AXUM_DSL_CACHE.set(cache).is_err() {
              return Ok(());
          }
          ::std::thread::Builder::new()
              .name("db-cache-observer".into())
              .spawn(move || {
                  let mut seen = data_version;
                  loop {
                      ::std::thread::sleep(::std::time::Duration::from_millis(1));
                      // An observer error cannot say what changed, so it counts as a commit.
                      let current = db.query_row("PRAGMA data_version", [], |row| row.get::<_, i64>(0)).unwrap_or(seen.wrapping_add(1));
                      if current != seen {
                          seen = current;
                          axum_dsl_cache_note_commit();
                      }
                  }
              })
              .map_err(|e| format!("database {path}: cannot start the response cache observer: {e}"))?;
          Ok(())
      }

      // A commit: a new generation, so every entry made before it becomes unreachable.
      fn axum_dsl_cache_note_commit() {
          if let Some(cache) = AXUM_DSL_CACHE.get() {
              cache.generation.fetch_add(1, ::std::sync::atomic::Ordering::SeqCst);
          }
      }

      fn axum_dsl_cache_version() -> Option<u64> {
          Some(AXUM_DSL_CACHE.get()?.generation.load(::std::sync::atomic::Ordering::SeqCst))
      }

      // Read on the way in, before any filter: a commit during a filter or the body can then never give an old
      // render the new generation. None (an observer error) bypasses the cache for this request.
      #[derive(Clone)]
      struct AxumDslCacheTicket(Option<u64>);

      async fn axum_dsl_cache_begin(mut request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          let reads = *request.method() == ::axum::http::Method::GET || *request.method() == ::axum::http::Method::HEAD;
          if reads && AXUM_DSL_CACHE_ROUTES.iter().any(|pattern| axum_dsl_skip_match(pattern, request.uri().path())) {
              let generation = axum_dsl_cache_version();
              request.extensions_mut().insert(AxumDslCacheTicket(generation));
          }
          next.run(request).await
      }

      fn axum_dsl_cache_directive(headers: &::axum::http::HeaderMap, rejected: &[&str]) -> bool {
          headers
              .get_all(::axum::http::header::CACHE_CONTROL)
              .iter()
              .filter_map(|value| value.to_str().ok())
              .any(|value| {
                  value.split(',').any(|directive| {
                      let name = directive.trim().split('=').next().unwrap_or("");
                      rejected.iter().any(|rejected| name.eq_ignore_ascii_case(rejected))
                  })
              })
      }

      fn axum_dsl_cache_eligible(method: &::axum::http::Method, headers: &::axum::http::HeaderMap) -> bool {
          use ::axum::http::header;
          (*method == ::axum::http::Method::GET || *method == ::axum::http::Method::HEAD)
              && headers.get(header::CONTENT_LENGTH).map_or(true, |value| value.as_bytes() == b"0")
              && !headers.contains_key(header::TRANSFER_ENCODING)
              && !headers.contains_key(header::RANGE)
              && !headers.contains_key(header::UPGRADE)
              && !axum_dsl_cache_directive(headers, &["no-cache", "no-store"])
              && !headers.get(header::PRAGMA).is_some_and(|value| value.as_bytes().eq_ignore_ascii_case(b"no-cache"))
      }

      // The same Accept-Encoding rule as :front (Rack::Deflater): gzip, or `*` when gzip is not named, above q=0.
      fn axum_dsl_cache_accepts_gzip(accept_encoding: &str) -> bool {
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

      // Length-prefixed fields, so no two requests can share a digest by moving bytes between fields. Every
      // request header is in it (Cookie, so one session; Accept; Turbo-Frame) but the validators and tracing ids.
      // The method is always GET: a HEAD is answered from the GET entry.
      fn axum_dsl_cache_key(generation: u64, route: &str, uri: &::axum::http::Uri, headers: &::axum::http::HeaderMap) -> Option<[u8; 32]> {
          use ::sha2::Digest as _;
          let mut digest = ::sha2::Sha256::new();
          let mut length = 0usize;
          let mut field = |value: &[u8]| {
              length += value.len() + 8;
              digest.update((value.len() as u64).to_le_bytes());
              digest.update(value);
          };
          field(&generation.to_le_bytes());
          field(route.as_bytes());
          field(b"GET");
          field(uri.to_string().as_bytes());
          let mut names: Vec<_> = headers.keys().collect();
          names.sort_unstable_by(|a, b| a.as_str().cmp(b.as_str()));
          for name in names {
              if matches!(name.as_str(), "if-none-match" | "if-modified-since" | "x-request-id" | "x-request-start") {
                  continue;
              }
              field(name.as_str().as_bytes());
              for value in headers.get_all(name) {
                  field(value.as_bytes());
              }
              field(b"");
          }
          if length > AXUM_DSL_CACHE_MAX_KEY_INPUT {
              return None;
          }
          Some(digest.finalize().into())
      }

      // What admission needs after a miss: the generation the request started in, and its key.
      struct AxumDslCacheAdmit {
          generation: u64,
          key: [u8; 32],
          gzip: bool,
      }

      enum AxumDslCacheOutcome {
          Hit(::axum::response::Response),
          Miss(Option<AxumDslCacheAdmit>),
      }

      fn axum_dsl_cache_get(cache: &AxumDslCache, generation: u64, key: &[u8; 32]) -> Option<::std::sync::Arc<AxumDslCacheEntry>> {
          if cache.generation.load(::std::sync::atomic::Ordering::SeqCst) != generation {
              return None;
          }
          let inner = cache.entries.read().unwrap_or_else(|p| p.into_inner());
          if inner.generation != generation {
              return None;
          }
          let entry = inner.entries.get(key)?.clone();
          if entry.expires <= ::std::time::Instant::now() {
              return None;
          }
          Some(entry)
      }

      // The generation is checked under the entries lock: an own commit bumps it before its write returns, so an
      // old render is never admitted under the next generation.
      fn axum_dsl_cache_put(cache: &AxumDslCache, admit: AxumDslCacheAdmit, entry: AxumDslCacheEntry) {
          if entry.size > cache.capacity {
              return;
          }
          let mut inner = cache.entries.write().unwrap_or_else(|p| p.into_inner());
          if cache.generation.load(::std::sync::atomic::Ordering::SeqCst) != admit.generation {
              return;
          }
          if inner.generation != admit.generation {
              inner.generation = admit.generation;
              inner.entries.clear();
              inner.order.clear();
              inner.bytes = 0;
          }
          if let Some(old) = inner.entries.remove(&admit.key) {
              inner.bytes -= old.size;
              inner.order.retain(|key| *key != admit.key);
          }
          while inner.bytes + entry.size > cache.capacity {
              let Some(oldest) = inner.order.pop_front() else { break };
              if let Some(old) = inner.entries.remove(&oldest) {
                  inner.bytes -= old.size;
              }
          }
          inner.bytes += entry.size;
          inner.order.push_back(admit.key);
          inner.entries.insert(admit.key, ::std::sync::Arc::new(entry));
      }

      // The first thing a cached route does, after every `before` filter has let the request through, so an
      // entry is never served to a request the filters would have stopped.
      fn axum_dsl_cache_lookup(
          route: &str,
          generation: Option<u64>,
          method: &::axum::http::Method,
          uri: &::axum::http::Uri,
          headers: &::axum::http::HeaderMap,
      ) -> AxumDslCacheOutcome {
          let (Some(cache), Some(generation)) = (AXUM_DSL_CACHE.get(), generation) else { return AxumDslCacheOutcome::Miss(None) };
          if !axum_dsl_cache_eligible(method, headers) {
              return AxumDslCacheOutcome::Miss(None);
          }
          let Some(key) = axum_dsl_cache_key(generation, route, uri, headers) else { return AxumDslCacheOutcome::Miss(None) };
          let gzip = AXUM_DSL_CACHE_GZIP
              && headers
                  .get(::axum::http::header::ACCEPT_ENCODING)
                  .and_then(|value| value.to_str().ok())
                  .is_some_and(axum_dsl_cache_accepts_gzip);
          if let Some(entry) = axum_dsl_cache_get(cache, generation, &key) {
              // The same rule as a route's own etag(...): a listed If-None-Match answers 304 with no body.
              if let Some(etag) = entry.headers.get(::axum::http::header::ETAG) {
                  let not_modified = headers
                      .get(::axum::http::header::IF_NONE_MATCH)
                      .and_then(|value| value.to_str().ok())
                      .zip(etag.to_str().ok())
                      .map(|(value, etag)| value.split(',').any(|tag| tag.trim() == etag))
                      .unwrap_or(false);
                  if not_modified {
                      let mut response = ::axum::response::IntoResponse::into_response(::axum::http::StatusCode::NOT_MODIFIED);
                      response.headers_mut().insert(::axum::http::header::ETAG, etag.clone());
                      return AxumDslCacheOutcome::Hit(response);
                  }
              }
              let mut response = ::axum::response::Response::new(::axum::body::Body::from(entry.body.clone()));
              *response.status_mut() = entry.status;
              *response.headers_mut() = entry.headers.clone();
              return AxumDslCacheOutcome::Hit(response);
          }
          // Even if a concurrent commit made the get miss, the put checks the original generation again.
          AxumDslCacheOutcome::Miss(Some(AxumDslCacheAdmit { generation, key, gzip }))
      }

      // The last thing a cached route does: keep a finished 200 whose body is in memory and small.
      async fn axum_dsl_cache_admit(admit: Option<AxumDslCacheAdmit>, response: ::axum::response::Response) -> ::axum::response::Response {
          let Some(admit) = admit else { return response };
          let Some(cache) = AXUM_DSL_CACHE.get() else { return response };
          if response.status() != ::axum::http::StatusCode::OK || axum_dsl_cache_directive(response.headers(), &["no-store", "no-transform"]) {
              return response;
          }
          let (mut parts, body) = response.into_parts();
          // Only a body whose whole length is known and small is collected, so a stream is never buffered here.
          let small = ::axum::body::HttpBody::size_hint(&body).exact().is_some_and(|length| length <= AXUM_DSL_CACHE_MAX_BODY as u64);
          if !small {
              return ::axum::response::Response::from_parts(parts, body);
          }
          let mut bytes = match ::axum::body::to_bytes(body, AXUM_DSL_CACHE_MAX_BODY).await {
              Ok(bytes) => bytes,
              Err(_) => {
                  let mut failed = ::axum::response::IntoResponse::into_response("response body could not be read");
                  *failed.status_mut() = ::axum::http::StatusCode::INTERNAL_SERVER_ERROR;
                  return failed;
              }
          };
          // With :front, store a gzip client's body already compressed, so a hit skips the deflater. The key
          // includes Accept-Encoding, so identity and gzip entries never share a body. The headers mirror what the
          // deflater would have put on this response, including the compressed Content-Length.
          let already_encoded = parts
              .headers
              .get(::axum::http::header::CONTENT_ENCODING)
              .and_then(|value| value.to_str().ok())
              .is_some_and(|value| !value.is_empty() && !value.eq_ignore_ascii_case("identity"));
          let event_stream = parts
              .headers
              .get(::axum::http::header::CONTENT_TYPE)
              .and_then(|value| value.to_str().ok())
              .is_some_and(|value| value.starts_with("text/event-stream"));
          if admit.gzip && !already_encoded && !event_stream {
              let mut encoder = ::flate2::write::GzEncoder::new(Vec::new(), ::flate2::Compression::default());
              let compressed = ::std::io::Write::write_all(&mut encoder, &bytes).and_then(|_| encoder.finish());
              if let Ok(compressed) = compressed {
                  bytes = ::axum::body::Bytes::from(compressed);
                  parts.headers.insert("content-encoding", ::axum::http::HeaderValue::from_static("gzip"));
                  parts.headers.insert("content-length", ::axum::http::HeaderValue::from(bytes.len()));
                  parts.headers.remove("accept-ranges");
              }
          }
          let mut headers = parts.headers.clone();
          headers.remove(::axum::http::header::SET_COOKIE);
          headers.remove(::axum::http::header::DATE);
          let size = bytes.len() + headers.iter().map(|(name, value)| name.as_str().len() + value.len()).sum::<usize>() + 64;
          let entry = AxumDslCacheEntry {
              status: parts.status,
              headers,
              body: bytes.clone(),
              expires: ::std::time::Instant::now() + AXUM_DSL_CACHE_TTL,
              size,
          };
          axum_dsl_cache_put(cache, admit, entry);
          ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(bytes))
      }
    RS
  end
end
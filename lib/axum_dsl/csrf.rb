# frozen_string_literal: true

module AxumDsl
  # use_layer :csrf (docs/sessions.md): a form carries the `authenticity_token` the view marker
  # `{{ csrf_token }}` writes, the same token travels in a signed cookie the layer sets, and every write
  # (anything but GET, HEAD and OPTIONS) must submit it -- as that form field, or as `X-CSRF-Token` -- or the
  # answer is 403. The token is 24 base58 characters from the same `random_token` runtime the body language
  # uses, the cookie is signed by the existing cookie runtime (the `cookies secret:` setting), and the
  # comparison is constant time. Nothing here is a new crate: std, the cookie runtime and rand.
  #
  # The layer also puts the token in the request's extensions (`AxumDslCsrfToken`), which is what
  # `{{ csrf_token }}` reads: a route handler takes `Extension(__csrf)` only when a view renders the marker
  # (Emit#request_extractors), and a `before` filter reads it from `request.extensions()`.
  #
  # A urlencoded write without the header is read into memory once, the field is taken out of it, and the
  # request is rebuilt with the same bytes, so axum's Form extractor still sees the body. A body over
  # AXUM_DSL_CSRF_BODY_LIMIT (2 MiB, axum's own form default) answers 413. A JSON write must use the header.
  module Csrf
    # The cookie the token travels in, and the form field and header it may be submitted as. The names are
    # contract: `test/e2e_csrf.sh` reads them over HTTP.
    COOKIE = "_axum_dsl_csrf"
    FIELD = "authenticity_token"
    HEADER = "x-csrf-token"
    BODY_LIMIT = 2 * 1024 * 1024

    # The Rust runtime, emitted only for a file that says `use_layer :csrf`. It sits after the cookie
    # runtime, whose `axum_dsl_cookie` (read, hmac) and `axum_dsl_set_cookie` (write) it calls, and after
    # `axum_dsl_random_token` when the layer added that builtin.
    RUNTIME = <<~RS
      // use_layer :csrf: a signed cookie holds the token, and every write must submit it. Written by the compiler.
      const AXUM_DSL_CSRF_COOKIE: &str = "#{COOKIE}";
      const AXUM_DSL_CSRF_FIELD: &str = "#{FIELD}";
      const AXUM_DSL_CSRF_HEADER: &str = "#{HEADER}";
      const AXUM_DSL_CSRF_BODY_LIMIT: usize = #{BODY_LIMIT};

      #[derive(Clone, Default)]
      #[allow(dead_code)]
      struct AxumDslCsrfToken(String);

      // Constant time: the length difference is public (a token is a fixed shape), the bytes are not.
      fn axum_dsl_ct_eq(left: &[u8], right: &[u8]) -> bool {
          if left.len() != right.len() {
              return false;
          }
          let mut diff = 0u8;
          for (a, b) in left.iter().zip(right.iter()) {
              diff |= *a ^ *b;
          }
          diff == 0
      }

      // One application/x-www-form-urlencoded value, with `+` and `%XX` decoded; a malformed escape is kept
      // literally, as a form decoder would not have produced it.
      fn axum_dsl_csrf_unquote(input: &[u8]) -> Vec<u8> {
          let mut out = Vec::with_capacity(input.len());
          let mut i = 0;
          while i < input.len() {
              match input[i] {
                  b'+' => {
                      out.push(b' ');
                      i += 1;
                  }
                  b'%' if i + 2 < input.len() => {
                      let high = (input[i + 1] as char).to_digit(16);
                      let low = (input[i + 2] as char).to_digit(16);
                      match (high, low) {
                          (Some(high), Some(low)) => {
                              out.push((high * 16 + low) as u8);
                              i += 3;
                          }
                          _ => {
                              out.push(input[i]);
                              i += 1;
                          }
                      }
                  }
                  byte => {
                      out.push(byte);
                      i += 1;
                  }
              }
          }
          out
      }

      // The first `authenticity_token` field of a urlencoded body, or None.
      fn axum_dsl_csrf_form_token(body: &[u8]) -> Option<String> {
          for pair in body.split(|byte| *byte == b'&') {
              let (name, value) = match pair.iter().position(|byte| *byte == b'=') {
                  Some(at) => (&pair[..at], &pair[at + 1..]),
                  None => (pair, &[][..]),
              };
              if axum_dsl_csrf_unquote(name).as_slice() == AXUM_DSL_CSRF_FIELD.as_bytes() {
                  return String::from_utf8(axum_dsl_csrf_unquote(value)).ok();
              }
          }
          None
      }

      async fn axum_dsl_csrf(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
          let method = request.method().clone();
          let safe = method == ::axum::http::Method::GET
              || method == ::axum::http::Method::HEAD
              || method == ::axum::http::Method::OPTIONS;
          let existing = axum_dsl_cookie(&request.headers(), AXUM_DSL_CSRF_COOKIE);
          let fresh = existing.is_none();
          let token = existing.unwrap_or_else(axum_dsl_random_token);
          let (mut request, submitted): (::axum::extract::Request, Option<String>) = if safe {
              (request, None)
          } else {
              let (parts, body) = request.into_parts();
              let header = parts
                  .headers
                  .get(AXUM_DSL_CSRF_HEADER)
                  .and_then(|value| value.to_str().ok())
                  .map(|value| value.to_string());
              if header.is_some() {
                  (::axum::http::Request::from_parts(parts, body), header)
              } else {
                  let urlencoded = parts
                      .headers
                      .get(::axum::http::header::CONTENT_TYPE)
                      .and_then(|value| value.to_str().ok())
                      .map(|value| value.starts_with("application/x-www-form-urlencoded"))
                      .unwrap_or(false);
                  if !urlencoded {
                      (::axum::http::Request::from_parts(parts, body), None)
                  } else {
                      match ::axum::body::to_bytes(body, AXUM_DSL_CSRF_BODY_LIMIT).await {
                          Ok(bytes) => {
                              let found = axum_dsl_csrf_form_token(&bytes);
                              (::axum::http::Request::from_parts(parts, ::axum::body::Body::from(bytes)), found)
                          }
                          Err(_) => {
                              let mut refused = ::axum::response::IntoResponse::into_response("request body is too large");
                              *refused.status_mut() = ::axum::http::StatusCode::PAYLOAD_TOO_LARGE;
                              return refused;
                          }
                      }
                  }
              }
          };
          if !safe {
              let valid = match submitted {
                  Some(ref value) => axum_dsl_ct_eq(value.as_bytes(), token.as_bytes()),
                  None => false,
              };
              if !valid {
                  let mut refused = ::axum::response::IntoResponse::into_response("CSRF token missing or invalid");
                  *refused.status_mut() = ::axum::http::StatusCode::FORBIDDEN;
                  return refused;
              }
          }
          request.extensions_mut().insert(AxumDslCsrfToken(token.clone()));
          let mut response = next.run(request).await;
          if fresh {
              // The cookie runtime's own writer and Set-Cookie appender: one token, one line.
              let cookie = axum_dsl_set_cookie(AXUM_DSL_CSRF_COOKIE, &token, true, "Lax", false, None);
              axum_dsl_apply_cookies(&mut response, &[cookie]);
          }
          response
      }
    RS

    module_function

    # The layer's Rust, for a file whose `use_layer :csrf` the emitter is placing. Empty for every other file,
    # so a service without the layer emits not one byte of it.
    def items(ir)
      return [] unless ir["layers"].to_a.any? { |l| l["name"] == "csrf" }

      ["// use_layer :csrf (a signed cookie and the authenticity_token field): written by the compiler",
       *RUNTIME.lines.map(&:chomp), ""]
    end
  end
end

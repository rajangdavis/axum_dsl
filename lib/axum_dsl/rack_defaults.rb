# frozen_string_literal: true

module AxumDsl
  # use_layer :rack_defaults (docs/dsl.md): the response headers a Rails app gets from its default middleware
  # stack, for the HTML a route renders. Each keyword is one part, so a service declares exactly the parts it wants:
  #   security_headers: true    Rails 8's default_headers (X-Frame-Options, X-XSS-Protection, X-Content-Type-Options,
  #                             X-Permitted-Cross-Domain-Policies, Referrer-Policy), set when the route sent none, on
  #                             every response but a Live one (a route's `headers "X-Rack-Defaults" => "live"`; "engine"
  #                             also leaves X-Version and X-Rev off and refreshes no cookie, and writes the session cookie
  #                             only when the request carried none, as Active Storage's engine controllers do; a redirect
  #                             of theirs adds the token "write_session" and gets the cookie whatever the request carried)
  #   version: / revision:      the names of two declared settings, written as X-Version and X-Rev (an empty
  #                             revision writes no header, as Rails drops a nil one)
  #   etag: true                Rack::ETag: a weak ETag over a 200 HTML or Turbo Stream body (any method), 304 (GET/HEAD only) for a matching
  #                             If-None-Match, and Cache-Control `max-age=0, private, must-revalidate` for a response
  #                             with an ETag, `no-cache` for one without (when the route set no Cache-Control)
  #   vary_accept: true         `Vary: Accept` on a successful response whose format came from the Accept header
  #   preload: ["app.css"]      a `Link: <url>; rel=preload; as=style; nopush` on a full HTML page, for files of the
  #                             fingerprinted `static` mount, comma-joined up to Rails' 1,000-byte header limit
  #   refresh_cookies: [names]  a cookie the request carried is written again (twenty years, HttpOnly, SameSite=Lax)
  #   session_cookie: "name"    a twenty-year HttpOnly session cookie, written on every response that does not carry it
  #   except: ["/assets"]       static mount prefixes the layer leaves alone
  # A response whose Content-Type is exactly `text/html; charset=UTF-8` is ActionDispatch::PublicExceptions' page (a controller's
  # is lower-case `utf-8`): written outside the controllers, it gets none of the above.
  # The ETag is a std hash (two SipHash words, 32 hex digits), not Rack's SHA-256: the validator is opaque to a client.
  module RackDefaults
    SECURITY_HEADERS = [
      %w[x-frame-options SAMEORIGIN], %w[x-xss-protection 0], %w[x-content-type-options nosniff],
      %w[x-permitted-cross-domain-policies none], %w[referrer-policy strict-origin-when-cross-origin]
    ].freeze
    PERMANENT_MAX_AGE = 20 * 31_556_952
    BODY_LIMIT = 16 * 1024 * 1024
    KEYWORDS = %i[security_headers version revision etag vary_accept preload refresh_cookies session_cookie except].freeze

    module_function

    def used?(ir) = ir["layers"].to_a.any? { |l| l["name"] == "rack_defaults" }

    def entry(ir) = ir["layers"].to_a.find { |l| l["name"] == "rack_defaults" }

    def layer_expr = "::axum::middleware::from_fn(axum_dsl_rack_defaults)"

    # Whether the layer reads a request header the body needs, so the page buffers the body.
    def buffers?(e) = e["etag"] || e["preload"]

    def runtime(ir)
      e = entry(ir)
      s = ->(text) { AxumDsl.rstr(text) }
      out = ["// use_layer :rack_defaults: Rails' default response headers for rendered HTML: written by the compiler"]
      except = e["except"].to_a
      unless except.empty?
        out << "const AXUM_DSL_RACK_EXCEPT: &[&str] = &[#{except.map { |p| s.(p) }.join(', ')}];"
        out << ""
        out << "fn axum_dsl_rack_exempt(path: &str) -> bool {"
        out << "    AXUM_DSL_RACK_EXCEPT.iter().any(|prefix| path == *prefix || path.strip_prefix(*prefix).map_or(false, |rest| rest.starts_with('/')))"
        out << "}"
        out << ""
      end
      if e["etag"]
        out.concat([
          # Rails' application layout renders csrf_meta_tags, a token masked afresh on every render, so Rack::ETag's
          # digest of a full page never repeats and a conditional GET of one (the reload Turbo makes after the failed
          # login's 401) is answered 200, never 304. Our pages carry no token: `unique` mixes in what stands for it,
          # this process's start and a per-response serial. A fragment (no layout, no token) keeps a stable digest.
          "fn axum_dsl_rack_digest(bytes: &[u8], unique: bool) -> String {",
          "    use ::std::hash::Hasher;",
          "    static SERIAL: ::std::sync::atomic::AtomicU64 = ::std::sync::atomic::AtomicU64::new(0);",
          "    static STARTED: ::std::sync::OnceLock<u128> = ::std::sync::OnceLock::new();",
          "    let salt = unique.then(|| {",
          "        let started = *STARTED.get_or_init(|| ::std::time::SystemTime::now().duration_since(::std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos()));",
          "        (started, SERIAL.fetch_add(1, ::std::sync::atomic::Ordering::Relaxed))",
          "    });",
          "    let mut first = ::std::collections::hash_map::DefaultHasher::new();",
          "    first.write(bytes);",
          "    let mut second = ::std::collections::hash_map::DefaultHasher::new();",
          "    second.write_u8(1);",
          "    second.write(bytes);",
          "    if let Some((started, serial)) = salt {",
          "        first.write_u128(started);",
          "        first.write_u64(serial);",
          "        second.write_u128(started);",
          "        second.write_u64(serial);",
          "    }",
          "    format!(\"{:016x}{:016x}\", first.finish(), second.finish())",
          "}",
          ""
        ])
      end
      if e["vary_accept"]
        out.concat([
          "// Rails' valid_accept_header: an XHR with an Accept, or an Accept that is not a browser's (no `, */*`).",
          "fn axum_dsl_rack_accept_format(accept: &str, xhr: bool) -> bool {",
          "    let packed: String = accept.chars().filter(|c| !c.is_whitespace()).collect();",
          "    !packed.is_empty() && (xhr || !(packed.contains(\",*/*\") || packed.contains(\"*/*,\")))",
          "}",
          ""
        ])
      end
      out << "async fn axum_dsl_rack_defaults(request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {"
      out << "    #[allow(unused_imports)]"
      out << "    use ::axum::http::{header, HeaderValue, Method, StatusCode};"
      unless except.empty?
        out << "    if axum_dsl_rack_exempt(request.uri().path()) {"
        out << "        return next.run(request).await;"
        out << "    }"
      end
      out << "    let is_get = matches!(*request.method(), Method::GET | Method::HEAD);"
      out << "    let _ = is_get;"
      header = ->(name) { "request.headers().get(#{name}).and_then(|v| v.to_str().ok()).map(str::to_owned)" }
      if e["vary_accept"]
        out << "    let accept = #{header.('header::ACCEPT')};"
        out << "    let xhr = request.headers().get(\"x-requested-with\").and_then(|v| v.to_str().ok()).map_or(false, |v| v.eq_ignore_ascii_case(\"xmlhttprequest\"));"
        out << "    let named_format = request.uri().query().map_or(false, |q| q.split('&').any(|p| p == \"format\" || p.starts_with(\"format=\")))"
        out << "        || request.uri().path().rsplit('/').next().map_or(false, |last| last.contains('.'));"
      end
      out << "    let if_none_match = #{header.('header::IF_NONE_MATCH')};" if e["etag"]
      cookies = e["refresh_cookies"].to_a
      if !cookies.empty? || e["session_cookie"]
        out << "    let cookie_header = request.headers().get_all(header::COOKIE).iter().filter_map(|v| v.to_str().ok()).collect::<Vec<_>>().join(\"; \");"
        out << "    let carried = |name: &str| -> Option<String> {"
        out << "        cookie_header.split(';').filter_map(|pair| pair.trim().split_once('=')).find(|(key, _)| *key == name).map(|(_, value)| value.to_owned())"
        out << "    };"
      end
      out << "    let mut response = next.run(request).await;"
      # ActionDispatch::PublicExceptions writes public/404.html outside any controller: Content-Type `text/html; charset=UTF-8`
      # (upper case, where a controller's is `utf-8`) and nothing else of the stack's, so that spelling leaves the layer off.
      out << "    if response.headers().get(header::CONTENT_TYPE).map_or(false, |v| v.as_bytes() == b\"text/html; charset=UTF-8\") {"
      out << "        return response;"
      out << "    }"
      out << "    let content_type = response.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or(\"\").to_ascii_lowercase();"
      out << "    let html = content_type.contains(\"html\");"
      out << "    let #{buffers?(e) ? 'mut ' : ''}full_page = false;"
      if buffers?(e)
        # Rack::ETag tags a 200/201 with a body whatever the method; only the 304 below is ConditionalGet's, for GET and HEAD.
        # The failed login (401) is a rendered page too, in the layout: it is read for the preload Link, and never tagged.
        out << "    if matches!(response.status().as_u16(), 200 | 201 | 401) && !response.headers().contains_key(header::CONTENT_ENCODING)"
        # Rack::ETag also tags a Turbo Stream answer (GET /rooms/:id/refresh) and a rendered script (the service worker);
        # file bodies stay unbuffered, as Rack skips to_path bodies.
        out << "        && (content_type.starts_with(\"text/html\") || content_type.starts_with(\"text/vnd.turbo-stream.html\") || content_type.starts_with(\"application/json\") || content_type.starts_with(\"text/javascript\"))"
        out << "    {"
        out << "        let (#{e['etag'] ? 'mut ' : ''}parts, body) = response.into_parts();"
        out << "        let bytes = match ::axum::body::to_bytes(body, #{BODY_LIMIT}).await {"
        out << "            Ok(bytes) => bytes,"
        out << "            Err(_) => return ::axum::response::Response::builder().status(StatusCode::INTERNAL_SERVER_ERROR).body(::axum::body::Body::empty()).unwrap(),"
        out << "        };"
        out << "        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(32)]).to_ascii_lowercase();"
        # Only the application layout starts with a doctype; turbo-rails' frame layout (`<html><head>`) gets no Link.
        out << "        full_page = head.trim_start().starts_with(\"<!doctype html\");"
        if e["etag"]
          out << "        if !bytes.is_empty() && matches!(parts.status.as_u16(), 200 | 201) && !parts.headers.contains_key(header::ETAG) && !parts.headers.contains_key(header::LAST_MODIFIED) {"
          out << "            if let Ok(value) = HeaderValue::from_str(&format!(\"W/\\\"{}\\\"\", axum_dsl_rack_digest(&bytes, full_page))) {"
          out << "                parts.headers.insert(header::ETAG, value);"
          out << "            }"
          out << "        }"
          out << "        let fresh = match (parts.headers.get(header::ETAG).and_then(|v| v.to_str().ok()), if_none_match.as_deref()) {"
          out << "            (Some(etag), Some(listed)) => listed.split(',').any(|tag| tag.trim() == etag || tag.trim() == \"*\"),"
          out << "            _ => false,"
          out << "        };"
          out << "        if fresh && is_get {"
          out << "            parts.status = StatusCode::NOT_MODIFIED;"
          out << "            parts.headers.remove(header::CONTENT_TYPE);"
          out << "            parts.headers.remove(header::CONTENT_LENGTH);"
          out << "            response = ::axum::response::Response::from_parts(parts, ::axum::body::Body::empty());"
          out << "        } else {"
          out << "            response = ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(bytes));"
          out << "        }"
        else
          out << "        response = ::axum::response::Response::from_parts(parts, ::axum::body::Body::from(bytes));"
        end
        out << "    }"
      end
      out << "    let status = response.status();"
      out << "    let _ = (&status, full_page, html, content_type);"
      out << "    let headers = response.headers_mut();"
      # A route's `headers "X-Rack-Defaults" => "live, engine"` says which Rails controller family answered; the
      # marker never reaches the client. `live` is an ActionController::Live controller (Active Storage streaming,
      # Users::AvatarsController): Live::Response skips `default_headers`, so it gets none of the security headers.
      # `engine` is an Active Storage engine controller (ActiveStorage::BaseController < ActionController::Base,
      # not ApplicationController), which never writes X-Version and X-Rev, nor refreshes the cookies ApplicationController
      # refreshes (refresh_cookies), and writes the session cookie only when the request carried none.
      out << "    let marker = headers.remove(\"x-rack-defaults\").and_then(|v| v.to_str().ok().map(str::to_owned)).unwrap_or_default();"
      out << "    let live = marker.split(',').any(|token| token.trim() == \"live\");"
      out << "    let engine = marker.split(',').any(|token| token.trim() == \"engine\");"
      out << "    let write_session = marker.split(',').any(|token| token.trim() == \"write_session\");"
      # `head(status)` (body.rb head_response) answered from the action, so a 4xx still refreshes the cookies.
      out << "    let from_action = marker.split(',').any(|token| token.trim() == \"head\");"
      # `unauthenticated`: an action Rails runs under allow_unauthenticated_access, which never resumes the session,
      # so the refresh_cookies are not written back (the session cookie still is, as Rails' session middleware does).
      out << "    let unauthenticated = marker.split(',').any(|token| token.trim() == \"unauthenticated\");"
      out << "    let _ = (live, engine, write_session, from_action, unauthenticated);"
      if e["security_headers"]
        # Rails' config.action_dispatch.default_headers are on every response, whatever its type, except a Live one.
        out << "    if !live {"
        SECURITY_HEADERS.each do |name, value|
          out << "        if !headers.contains_key(#{s.(name)}) {"
          out << "            headers.insert(#{s.(name)}, HeaderValue::from_static(#{s.(value)}));"
          out << "        }"
        end
        out << "    }"
      end
      if e["version"]
        out << "    if let (false, Ok(value)) = (engine, HeaderValue::from_str(&settings().#{e['version']})) {"
        out << "        headers.insert(\"x-version\", value);"
        out << "    }"
      end
      if e["revision"]
        out << "    if let (false, Ok(value)) = (engine, HeaderValue::from_str(&settings().#{e['revision']})) {"
        out << "        if !value.is_empty() {"
        out << "            headers.insert(\"x-rev\", value);"
        out << "        }"
        out << "    }"
      end
      if e["preload"]
        # ActionView send_preload_links_header: comma-joined, and a link that would take the header past 1,000
        # bytes is left out (Propshaft renders each stylesheet on its own, so a later, shorter one may still fit).
        link = e["preload_urls"].map { |url| "<#{url}>; rel=preload; as=style; nopush" }
                                .each_with_object(+"") { |l, h| h << (h.empty? ? l : ",#{l}") if h.bytesize + l.bytesize + (h.empty? ? 0 : 1) <= 1_000 }
        out << "    if full_page && !headers.contains_key(header::LINK) {"
        out << "        headers.insert(header::LINK, HeaderValue::from_static(#{s.(link)}));"
        out << "    }"
      end
      if e["vary_accept"]
        out << "    if (status.is_success() && status != StatusCode::NO_CONTENT || status == StatusCode::UNAUTHORIZED) && !named_format && accept.as_deref().map_or(false, |a| axum_dsl_rack_accept_format(a, xhr)) {"
        out << "        let varies = headers.get_all(header::VARY).iter().any(|v| v.to_str().map_or(false, |v| v.to_ascii_lowercase().contains(\"accept\")));"
        out << "        if !varies {"
        out << "            headers.append(header::VARY, HeaderValue::from_static(\"Accept\"));"
        out << "        }"
        out << "    }"
      end
      if e["etag"]
        out << "    if !headers.contains_key(header::CACHE_CONTROL) {"
        out << "        let value = if headers.contains_key(header::ETAG) { \"max-age=0, private, must-revalidate\" } else { \"no-cache\" };"
        out << "        headers.insert(header::CACHE_CONTROL, HeaderValue::from_static(value));"
        out << "    }"
      end
      unless cookies.empty? && !e["session_cookie"]
        redirect_to_login = "(status.is_redirection() && headers.get(header::LOCATION).and_then(|v| v.to_str().ok()).map_or(false, |l| l.ends_with(\"/session/new\")))"
        out << "    if (status.as_u16() < 400 || status == StatusCode::UNAUTHORIZED || from_action) && !#{redirect_to_login} {"
        out << "        let written = |headers: &::axum::http::HeaderMap, name: &str| headers.get_all(header::SET_COOKIE).iter().any(|v| v.to_str().map_or(false, |v| v.starts_with(&format!(\"{name}=\"))));"
        cookies.each do |name|
          out << "        if !engine && !unauthenticated && !written(headers, #{s.(name)}) {"
          out << "            if let Some(value) = carried(#{s.(name)}) {"
          out << "                if let Ok(line) = HeaderValue::from_str(&format!(\"{}={}; Path=/; Max-Age=#{PERMANENT_MAX_AGE}; SameSite=Lax; HttpOnly\", #{s.(name)}, value)) {"
          out << "                    headers.append(header::SET_COOKIE, line);"
          out << "                }"
          out << "            }"
          out << "        }"
        end
        if e["session_cookie"]
          name = e["session_cookie"]
          # A route that writes the session cookie with an empty value (no cookie came for it to pass on) has written
          # nothing: drop that line, so the cookie is passed on or made fresh below rather than read as cleared.
          out << "        let (bare, empty) = (format!(\"{}=\", #{s.(name)}), format!(\"{}=;\", #{s.(name)}));"
          out << "        let kept: Vec<HeaderValue> = headers.get_all(header::SET_COOKIE).iter().filter(|v| v.to_str().map_or(true, |v| v != bare && !v.starts_with(&empty))).cloned().collect();"
          out << "        headers.remove(header::SET_COOKIE);"
          out << "        for line in kept { headers.append(header::SET_COOKIE, line); }"
          out << "        if !written(headers, #{s.(name)}) && !(engine && !write_session && carried(#{s.(name)}).map_or(false, |v| !v.is_empty())) {"
          out << "            let value = carried(#{s.(name)}).filter(|v| !v.is_empty()).unwrap_or_else(axum_dsl_random_token);"
          out << "            if let Ok(line) = HeaderValue::from_str(&format!(\"{}={}; Path=/; Max-Age=#{PERMANENT_MAX_AGE}; SameSite=Lax; HttpOnly\", #{s.(name)}, value)) {"
          out << "                headers.append(header::SET_COOKIE, line);"
          out << "            }"
          out << "        }"
        end
        out << "    }"
      end
      out << "    response"
      out << "}"
      out
    end
  end
end

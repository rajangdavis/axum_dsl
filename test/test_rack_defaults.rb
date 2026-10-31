# frozen_string_literal: true

# `use_layer :rack_defaults` (docs/dsl.md), asserted on the emitted crate: security headers are for HTML
# responses only, a Turbo Stream 200 gets Rack::ETag, and the Link preload is for a full layout (a body
# starting with a doctype), not a turbo-frame fragment. The running headers are checked by campfire parity.
#
#   ruby -Ilib test/test_rack_defaults.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestRackDefaults < Minitest::Test
  def compile_files(body, extra: {})
    Dir.mktmpdir("rack") do |dir|
      extra.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "rack.axum.rb")
      File.write(file, "server \"rack\", version: \"0.1.0\"\n#{body}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def test_security_headers_are_on_every_response_but_a_live_one
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, security_headers: true, etag: true
      get "/" do
        text("ok")
      end
      get "/avatar" do
        headers "X-Rack-Defaults" => "live"
        text("ok")
      end
    RB
    assert_includes main, 'let marker = headers.remove("x-rack-defaults")'
    assert_includes main, 'token.trim() == "live"'
    assert_includes main, 'token.trim() == "engine"'
    assert_includes main, "if !live {"
    refute_includes main, "if html {", "the type of the body no longer decides"
    assert_includes main, 'headers.insert("x-frame-options", HeaderValue::from_static("SAMEORIGIN"));'
  end

  def test_an_empty_204_halt_has_no_content_type
    main = compile_files(<<~RB)["src/main.rs"]
      get "/gone" do
        return halt(204, "") if user_agent == "x"
        "ok"
      end
      get "/missing" do
        return halt(404, "") if user_agent == "x"
        "ok"
      end
    RB
    assert_includes main, "(::axum::http::StatusCode::from_u16(204).unwrap(), ())"
    refute_includes main, "(::axum::http::StatusCode::from_u16(404).unwrap(), ())", "only 204, 205 and 304 are bare"
  end

  def test_a_turbo_stream_200_is_buffered_for_etag
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, etag: true
      get "/" do
        text("ok")
      end
    RB
    assert_includes main, "text/vnd.turbo-stream.html"
    assert_includes main, "application/json"
    assert_includes main, "axum_dsl_rack_digest(&bytes, full_page)"
    assert_includes main, "parts.status = StatusCode::NOT_MODIFIED;"
  end

  # Rails' layout renders a freshly masked CSRF token, so a full page's Rack::ETag never repeats and its reload is a
  # 200 (auth/sign_in/error: Turbo reloads /session/new after the 401); a fragment's digest stays stable.
  def test_a_full_page_etag_never_repeats
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, etag: true
      get "/" do
        text("ok")
      end
    RB
    assert_includes main, "fn axum_dsl_rack_digest(bytes: &[u8], unique: bool) -> String {"
    assert_includes main, "SERIAL.fetch_add(1, ::std::sync::atomic::Ordering::Relaxed)"
    assert_includes main, "if let Some((started, serial)) = salt {"
  end

  def test_link_preload_is_only_for_a_doctype_body
    main = compile_files(<<~RB, extra: { "public/app.css" => "a{}\n" })["src/main.rs"]
      static "/assets", dir: "public", digest: true
      use_layer :rack_defaults, preload: ["app.css"]
      get "/" do
        "ok"
      end
    RB
    assert_includes main, 'full_page = head.trim_start().starts_with("<!doctype html");'
    refute_includes main, 'starts_with("<html")'
    assert_includes main, 'if full_page && !headers.contains_key(header::LINK) {'
  end

  def test_an_empty_route_written_session_cookie_is_dropped
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, session_cookie: "_app_session"
      get "/" do
        "ok"
      end
    RB
    assert_includes main, 'v != bare && !v.starts_with(&empty)', "an empty value is not a write"
    assert_includes main, '.filter(|v| !v.is_empty()).unwrap_or_else(axum_dsl_random_token)', "an empty carried value gets a fresh token"
  end

  def test_etag_applies_to_any_method_but_only_get_answers_304
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, etag: true
      post "/" do
        text("ok")
      end
    RB
    assert_includes main, "if matches!(response.status().as_u16(), 200 | 201 | 401)"
    refute_includes main, "if is_get && matches!(response.status().as_u16(), 200 | 201)"
    assert_includes main, "if fresh && is_get {"
  end

  def test_an_engine_response_refreshes_no_cookie_and_writes_the_session_cookie_only_when_not_carried
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, refresh_cookies: ["token"], session_cookie: "_app_session"
      get "/" do
        headers "X-Rack-Defaults" => "engine"
        text("ok")
      end
    RB
    assert_includes main, "if !engine && !written(headers, \"token\") {"
    assert_includes main, "if !written(headers, \"_app_session\") && !(engine && !write_session && carried(\"_app_session\").map_or(false, |v| !v.is_empty())) {"
    refute_includes main, "&& !engine && !(status.is_redirection()"
  end

  def test_an_engine_redirect_can_ask_for_the_session_cookie_whatever_the_request_carried
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, session_cookie: "_app_session"
      get "/" do
        headers "X-Rack-Defaults" => "engine, write_session"
        text("ok")
      end
    RB
    assert_includes main, "let write_session = marker.split(',').any(|token| token.trim() == \"write_session\");"
  end

  def test_a_failed_login_page_gets_the_link_the_vary_and_the_session_cookie_and_no_etag
    main = compile_files(<<~RB, extra: { "public/a.css" => "a{}\n" })["src/main.rs"]
      static "/assets", dir: "public", digest: true
      use_layer :rack_defaults, etag: true, vary_accept: true, preload: ["a.css"], session_cookie: "_app_session"
      get "/" do
        "ok"
      end
    RB
    assert_includes main, "200 | 201 | 401"
    assert_includes main, "matches!(parts.status.as_u16(), 200 | 201)"
    assert_includes main, "|| status == StatusCode::UNAUTHORIZED) && !named_format"
    assert_includes main, "(status.as_u16() < 400 || status == StatusCode::UNAUTHORIZED)"
  end

  def test_the_public_exceptions_page_leaves_the_layer
    main = compile_files(<<~RB)["src/main.rs"]
      use_layer :rack_defaults, security_headers: true
      get "/" do
        "ok"
      end
    RB
    assert_includes main, "v.as_bytes() == b\"text/html; charset=UTF-8\") {"
  end

  def test_a_served_file_can_leave_the_layer_and_carry_a_max_age
    main = compile_files(<<~RB, extra: { "public/e.html" => "<p>x</p>\n" })["src/main.rs"]
      serve_file "/e.html", from: "public/e.html", max_age: 2592000
      use_layer :rack_defaults, security_headers: true, except: ["/e.html"]
      get "/" do
        text("ok")
      end
    RB
    assert_includes main, "const AXUM_DSL_RACK_EXCEPT: &[&str] = &[\"/e.html\"];"
    assert_includes main, "\"max-age=2592000, public\""
    assert_includes main, ".layer(::axum::middleware::from_fn(axum_dsl_serve_file_headers_0))"
  end

  def test_link_preload_is_comma_joined_up_to_a_thousand_bytes
    names = (1..40).map { |i| "style#{i}.css" }
    main = compile_files(<<~RB, extra: names.to_h { |n| ["public/#{n}", "a{}\n"] })["src/main.rs"]
      static "/assets", dir: "public", digest: true
      use_layer :rack_defaults, preload: #{names.inspect}
      get "/" do
        "ok"
      end
    RB
    link = main[/HeaderValue::from_static\("(<\/assets\/style1-[^"]*)"\)/, 1]
    refute_nil link, "the Link value is one static string"
    assert_includes link, "; nopush,</assets/style2-", "Rails joins the links with a bare comma"
    assert_operator link.bytesize, :<=, 1_000
    refute_includes link, "style40-", "a link past the 1,000-byte limit is left out"
  end
end

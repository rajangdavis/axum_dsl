# frozen_string_literal: true

# `head(status)`, Rails' `head :forbidden` from an action, `turbo_stream_request?`, Rails' `request.format.turbo_stream?`,
# and an empty `etag("")`, Rails' `stale?(etag: nil)`, which writes no ETag.
#
#   ruby -Ilib test/test_head.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestHead < Minitest::Test
  def main(src)
    Dir.mktmpdir("head") do |dir|
      file = File.join(dir, "head.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def app(body)
    <<~RB
      server "head", version: "0.1.0"
      use_layer :rack_defaults, refresh_cookies: ["session_token"], session_cookie: "_app_session"

      get "/" do
        #{body}
      end
    RB
  end

  def test_head_is_an_empty_html_response_marked_for_the_cookie_refresh
    out = main(app("head(403)"))
    assert_includes out, '(::axum::http::header::CONTENT_TYPE, "text/html")'
    assert_includes out, '(::axum::http::HeaderName::from_static("x-rack-defaults"), "head")'
    assert_includes out, "status == StatusCode::UNAUTHORIZED || from_action)"
  end

  def test_head_no_content_has_no_content_type
    out = main(app("head(204)"))
    refute_includes out, '(::axum::http::header::CONTENT_TYPE, "text/html")'
  end

  def test_head_takes_one_status
    err = assert_raises(AxumDsl::CompileError) { main(app('head(403, "no")')) }
    assert_match(/head takes one status/, err.message)
  end

  def test_turbo_stream_request_reads_the_accept_header
    out = main(app('turbo_stream_request? ? text("stream") : text("page")'))
    assert_includes out, "fn axum_dsl_turbo_stream_request(headers: &::axum::http::HeaderMap) -> bool {"
    assert_includes out, "axum_dsl_turbo_stream_request(&__headers)"
  end

  def test_an_empty_etag_writes_none
    out = main(app('etag(request_ip.empty? ? "" : "W/\\"v1\\"")' + "\n  text(\"ok\")"))
    assert_includes out, "if let (false, Ok(__etag_value)) = (__etag.is_empty(), ::axum::http::HeaderValue::from_str(&__etag)) {"
  end
end

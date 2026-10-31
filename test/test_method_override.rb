# frozen_string_literal: true

# `use_layer :method_override` (docs/dsl.md), asserted on the emitted crate: the runtime reads `_method` and
# X-HTTP-Method-Override from a POST, the body goes back unchanged, and the router is wrapped from outside so
# the rewrite comes before routing. test/e2e_method_override.sh drives the running service.
#
#   ruby -Ilib test/test_method_override.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestMethodOverride < Minitest::Test
  def compile_files(body)
    Dir.mktmpdir("override") do |dir|
      file = File.join(dir, "override.axum.rb")
      File.write(file, "server \"override\", version: \"0.1.0\"\n#{body}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def main(body) = compile_files(body)["src/main.rs"]

  APP = <<~RB
    use_layer :method_override
    delete "/notes" do
      text("gone")
    end
  RB

  def test_the_runtime_reads_the_field_and_the_header_of_a_post
    main = main(APP)
    assert_includes main, "if request.method() != ::axum::http::Method::POST {"
    assert_includes main, '"application/x-www-form-urlencoded"'
    assert_includes main, 'b"_method"'
    assert_includes main, 'request.headers().get("x-http-method-override")'
    assert_includes main, '&["GET", "HEAD", "PUT", "POST", "DELETE", "OPTIONS", "PATCH", "LINK", "UNLINK"]'
    assert_includes main, ".to_ascii_uppercase()"
  end

  def test_the_body_is_buffered_and_put_back
    main = main(APP)
    assert_includes main, "::axum::body::to_bytes(body, AXUM_DSL_METHOD_OVERRIDE_BODY_LIMIT)"
    assert_includes main, "request = ::axum::http::Request::from_parts(parts, ::axum::body::Body::from(bytes));"
    assert_includes main, "StatusCode::PAYLOAD_TOO_LARGE"
  end

  def test_the_router_is_wrapped_from_outside_not_layered
    main = main(<<~RB)
      use_layer :method_override
      use_layer :fetch_metadata
      use_layer :trace
      delete "/notes" do
        text("gone")
      end
    RB
    wrap = "let router = axum::Router::new().fallback_service(router).layer(axum::middleware::from_fn(axum_dsl_method_override));"
    assert_includes main, wrap
    assert_operator main.index("axum_dsl_fetch_metadata))"), :<, main.index(wrap), "outside :fetch_metadata, so it sees the rewritten method"
    assert_operator main.index("TraceLayer"), :<, main.index(wrap), "and outside :trace"
    assert_operator main.index(wrap), :<, main.index("into_make_service_with_connect_info")
  end

  def test_no_layer_no_runtime
    main = main("delete \"/notes\" do\n  text(\"gone\")\nend\n")
    refute_includes main, "method_override"
  end

  def test_it_takes_no_keywords_and_only_once
    error = assert_raises(AxumDsl::CompileError) { compile_files("use_layer :method_override, etag: true\n") }
    assert_includes error.message, "`use_layer :method_override` takes no keywords, so it does not take `etag:`"
    error = assert_raises(AxumDsl::CompileError) { compile_files("use_layer :method_override\nuse_layer :method_override\n") }
    assert_includes error.message, "duplicate `use_layer :method_override`"
  end
end

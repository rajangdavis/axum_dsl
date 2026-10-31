# frozen_string_literal: true

# `url_encode(text)` (docs/body-language.md), asserted on the emitted crate: URI.encode_www_form_component's
# escaping as the Rust the compiler writes, the call site, and the refusals. The bytes are not run here.
#
#   ruby -Ilib test/test_url_encode.rb
require "minitest/autorun"
require "tmpdir"
require "uri"
require "axum_dsl"

class TestUrlEncode < Minitest::Test
  HEAD = "server \"url\", version: \"0.1.0\"\n"

  def files(body)
    Dir.mktmpdir("url") do |dir|
      file = File.join(dir, "url.axum.rb")
      File.write(file, HEAD + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def main(body) = files(body).fetch("src/main.rs")

  def refusal(body)
    error = assert_raises(AxumDsl::CompileError) { files(body) }
    error.message
  end

  def test_the_route_calls_the_encoder
    rust = main(<<~RB)
      params :Q do
        field :email, :string, in: :query
      end
      get "/session/new", params: :Q do
        text(url_encode(params[:email]))
      end
    RB
    assert_includes rust, "fn axum_dsl_url_encode(text: &str) -> String"
    assert_includes rust, "axum_dsl_url_encode("
    # The kept set is Ruby's own, and it is not RFC 3986's unreserved set: `URI.encode_www_form_component`
    # (Rack::Utils.escape) keeps `*` and writes `~` as %7E, while `ERB::Util.url_encode` keeps `~`.
    assert_equal "*", URI.encode_www_form_component("*")
    assert_equal "%7E", URI.encode_www_form_component("~")
    assert_includes rust, "| b'-' | b'.' | b'_' | b'*' => out.push(byte as char)", "Ruby's form encoding keeps *"
    refute_includes rust, "b'~' => out.push(byte as char)", "a ~ is escaped, as Ruby escapes it"
    assert_includes rust, "b' ' => out.push('+')", "a space is a +, as Rack writes it"
    assert_includes rust, 'out.push_str(&format!("%{byte:02X}"))', "everything else is an upper-case %XX"
  end

  def test_the_runtime_is_only_written_for_a_call_that_uses_it
    refute_includes main("get \"/\" do\n  \"ok\"\nend\n"), "axum_dsl_url_encode"
  end

  def test_a_non_string_is_refused
    message = refusal("get \"/x\" do\n  url_encode(1)\nend\n")
    assert_includes message, "url_encode takes a string"
  end

  def test_wrong_arity_is_refused
    assert_includes refusal("get \"/x\" do\n  url_encode\nend\n"), "url_encode takes exactly one string"
    assert_includes refusal("get \"/x\" do\n  url_encode(\"a\", \"b\")\nend\n"), "url_encode takes exactly one string"
  end
end

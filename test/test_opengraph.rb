# frozen_string_literal: true

#
#   ruby -Ilib test/test_opengraph.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

# `opengraph_unfurl(url)` (lib/axum_dsl/opengraph.rb): Campfire's Opengraph::Metadata.from_url, asserted on the emitted
# crate. The behaviour itself is checked against Rails by campfire_axum_dsl's differential runs (public URLs, private
# and unresolvable hosts, media URLs, a page without a charset).
class TestOpengraph < Minitest::Test
  def compile(src)
    Dir.mktmpdir("og") do |dir|
      file = File.join(dir, "og.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  APP = <<~RB
    server "og", version: "0.1.0"

    params :Unfurl do
      field :url, :string, in: :form
    end

    post "/unfurl", params: :Unfurl do
      found = opengraph_unfurl(params[:url])
      return halt(204, "") if found.nil?
      text(found, content_type: "application/json; charset=utf-8")
    end
  RB

  def test_the_runtime_and_its_crates_come_with_a_call
    out = compile(APP)
    main = out["src/main.rs"]
    assert_includes main, "async fn axum_dsl_opengraph_unfurl(url: &str) -> Option<String>"
    assert_includes main, "axum_dsl_opengraph_unfurl(url.as_str()).await"
    assert_includes main, "fn axum_dsl_og_blocked_address(ip: ::std::net::IpAddr) -> bool"
    assert_includes out["Cargo.toml"], 'reqwest = { version = "0.12", default-features = false, features = ["rustls-tls-native-roots"] }'
    assert_includes out["Cargo.toml"], 'scraper = { version = "0.20", features = ["deterministic"] }'
  end

  def test_no_call_no_runtime
    out = compile(APP.sub(/found = .*\n.*\n.*\n/, "text(params[:url])\n"))
    refute_includes out["src/main.rs"], "axum_dsl_opengraph_unfurl"
    refute_includes out["Cargo.toml"], "reqwest"
  end

  def test_it_takes_one_string
    err = assert_raises(AxumDsl::CompileError) { compile(APP.sub("opengraph_unfurl(params[:url])", "opengraph_unfurl(1)")) }
    assert_includes err.message, "opengraph_unfurl takes a string"
  end
end

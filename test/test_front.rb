# frozen_string_literal: true

# `use_layer :front` (docs/dsl.md), asserted on the emitted crate: where the layer sits, the dependency it adds,
# and the header rules it writes. No cargo and no HTTP; test/e2e_campfire.sh checks the headers on the running
# service (gzip, Vary, X-Cache, an asset's Cache-Control).
#
#   ruby -Ilib test/test_front.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestFront < Minitest::Test
  def compile_files(body, extra: {})
    Dir.mktmpdir("front") do |dir|
      extra.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "front.axum.rb")
      File.write(file, "server \"front\", version: \"0.1.0\"\n#{body}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  PAGE = <<~RB
    get "/" do
      "ok"
    end
  RB

  def test_the_layer_is_the_outermost_but_trace_and_adds_flate2
    files = compile_files("use_layer :front\nuse_layer :trace\nuse_layer :rack_defaults, etag: true\n#{PAGE}")
    main = files["src/main.rs"]
    order = main.scan(/\.layer\(([^\n]*)\)/).flatten.map { |l| l[/axum_dsl_\w+|TraceLayer/] }.compact
    assert_operator order.index("axum_dsl_rack_defaults"), :<, order.index("axum_dsl_front"), "the ETag is over the identity body"
    assert_includes files["Cargo.toml"], 'flate2 = "1"'
    assert_includes main, "const AXUM_DSL_FRONT_CAPACITY: usize = 64 * 1024 * 1024;", "Thruster's CACHE_SIZE default"
  end

  def test_cache_mb_sizes_the_cache
    main = compile_files("use_layer :front, cache_mb: 0\n#{PAGE}")["src/main.rs"]
    assert_includes main, "const AXUM_DSL_FRONT_CAPACITY: usize = 0 * 1024 * 1024;"
  end

  def test_the_header_rules_are_written
    main = compile_files("use_layer :front\n#{PAGE}")["src/main.rs"]
    ['"x-cache", ::axum::http::HeaderValue::from_static("bypass")', '::axum::http::HeaderValue::from_static("hit")',
     '::axum::http::HeaderValue::from_static("miss")', 'tokens.push("accept-encoding".to_owned())',
     '"content-encoding", ::axum::http::HeaderValue::from_static("gzip")'].each do |line|
      assert_includes main, line
    end
  end

  def test_a_bypassed_request_repeats_accept_encoding_in_vary
    main = compile_files("use_layer :front\n#{PAGE}")["src/main.rs"]
    assert_includes main, "axum_dsl_front_deflate(request, next, true)", "the uncacheable path appends gzhttp's Vary"
    assert_includes main, "axum_dsl_front_deflate(request, next, false)", "the cache path replaces it"
    assert_includes main, "if bypass && (had_vary || !blocked) {"
    assert_includes main, "let skip = !accepts || blocked;", "a client that refuses gzip (a media range request) still gets Deflater's Vary"
  end

  def test_without_the_layer_nothing_is_written
    files = compile_files(PAGE)
    refute_includes files["src/main.rs"], "axum_dsl_front"
    refute_includes files["Cargo.toml"], "flate2"
  end

  def test_a_max_age_mount_without_a_digest_keeps_accept_ranges
    main = compile_files("static \"/assets\", dir: \"public\", max_age: 60\n#{PAGE}", extra: { "public/a.css" => "a{}\n" })["src/main.rs"]
    assert_includes main, '"max-age=60, public"'
    refute_includes main, 'headers.remove("accept-ranges");'
  end
end

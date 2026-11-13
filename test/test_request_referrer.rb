# frozen_string_literal: true

# `request_referrer`: Rails' request.referrer, the Referer header ("" without one), where link_back goes.
#
#   ruby -Ilib test/test_request_referrer.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestRequestReferrer < Minitest::Test
  def main(body)
    Dir.mktmpdir("referrer") do |dir|
      file = File.join(dir, "app.axum.rb")
      File.write(file, <<~RB)
        server "referrer", version: "0.1.0"
        get "/" do
          #{body}
        end
      RB
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def test_reads_the_referer_header
    out = main('back = request_referrer' "\n" '  text(back.empty? ? "/" : back)')
    assert_includes out, "axum_dsl_request_referrer(&__headers)"
    assert_includes out, "fn axum_dsl_request_referrer("
    assert_includes out, "header::REFERER"
  end

  def test_takes_no_arguments
    err = assert_raises(AxumDsl::CompileError) { main('text(request_referrer(1))') }
    assert_includes err.message, "request_referrer takes no arguments"
  end

  def test_runtime_left_out_when_unused
    refute_includes main('text("hi")'), "fn axum_dsl_request_referrer("
  end
end

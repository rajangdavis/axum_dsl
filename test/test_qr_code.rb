# frozen_string_literal: true

# `qr_code_svg(text)` and `urlsafe_decode64(text)` (docs/body-language.md), asserted on the emitted crate: the
# runtime is written only for the calls a body makes, both give an Option<String>, and the encoder follows
# rqrcode_core. The SVG bytes themselves are checked by the Campfire parity run (GET /qr_code/:id).
#
#   ruby -Ilib test/test_qr_code.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestQrCode < Minitest::Test
  def main_rs(body)
    Dir.mktmpdir("qr") do |dir|
      file = File.join(dir, "qr.axum.rb")
      File.write(file, "server \"qr\", version: \"0.1.0\"\n#{body}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  QR_ROUTE = <<~RB
    params :QrPath do
      field :id, :string, in: :path
    end
    get "/qr_code/:id", params: :QrPath do
      url = urlsafe_decode64(params[:id])
      return halt(500, "") if url.nil?
      svg = qr_code_svg(url)
      return halt(422, "") if svg.nil?
      text(svg, content_type: "image/svg+xml; charset=utf-8")
    end
  RB

  def test_the_route_calls_both_runtimes
    main = main_rs(QR_ROUTE)
    assert_includes main, "fn axum_dsl_urlsafe_decode64(text: &str) -> Option<String>"
    assert_includes main, "fn axum_dsl_qr_code_svg(text: &str) -> Option<String>"
    assert_includes main, "axum_dsl_urlsafe_decode64("
    assert_includes main, "axum_dsl_qr_code_svg("
  end

  def test_the_encoder_follows_rqrcode_core
    main = main_rs(QR_ROUTE)
    assert_includes main, "// QRERRORCORRECTLEVEL[:h]", "error correction level H"
    assert_includes main, "< MAX_BITS_H[v - 1]", "the smallest version with strictly more capacity than the bits"
    assert_includes main, 'viewBox="0 0 {dimension} {dimension}" shape-rendering="crispEdges"'
    assert_includes main, 'fill="white"'
    assert_includes main, 'fill="black"'
  end

  def test_the_runtime_is_only_written_for_a_call_that_uses_it
    main = main_rs(<<~RB)
      get "/" do
        text("ok")
      end
    RB
    refute_includes main, "axum_dsl_qr"
    refute_includes main, "axum_dsl_urlsafe_decode64"
    only_decode = main_rs(<<~RB)
      params :P do
        field :id, :string, in: :path
      end
      get "/d/:id", params: :P do
        url = urlsafe_decode64(params[:id])
        return halt(500, "") if url.nil?
        text(url)
      end
    RB
    assert_includes only_decode, "fn axum_dsl_urlsafe_decode64("
    refute_includes only_decode, "mod axum_dsl_qr"
  end
end

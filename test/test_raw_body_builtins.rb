# frozen_string_literal: true

# The raw-body route builtins: `request_upload(:name)` (a multipart body's file part beside `request_body`) and
# `action_text_html(html)` (the body Action Text stores). Asserted on the emitted crate; Campfire's differential bot API
# scenarios check both against Rails, and its fuzz run checks action_text_html against ActionText::Content.
#
#   ruby -Ilib test/test_raw_body_builtins.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestRawBodyBuiltins < Minitest::Test
  def files(src)
    Dir.mktmpdir("rawbody") do |dir|
      file = File.join(dir, "rawbody.axum.rb")
      File.write(file, "server \"rawbody\", version: \"0.1.0\"\n#{src}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def test_request_upload_reads_the_raw_body_and_headers
    out = files(<<~RB)
      post "/post" do
        file = request_upload(:attachment)
        raw = request_body
        text(file.nil? ? raw : file.filename)
      end
    RB
    main = out["src/main.rs"]
    assert_includes main, "fn axum_dsl_request_upload(headers: &::axum::http::HeaderMap, body: &[u8], name: &str) -> Option<AxumDslUpload>"
    assert_includes main, 'axum_dsl_request_upload(&__headers, &__body, "attachment")'
    assert_match(/__headers: ::axum::http::HeaderMap.*__body: ::axum::body::Bytes\)/, main)
    assert_includes out["Cargo.toml"], "md-5"
  end

  def test_request_upload_takes_a_symbol
    err = assert_raises(AxumDsl::CompileError) { files(<<~RB) }
      post "/post" do
        file = request_upload("attachment")
        text(file&.filename || "")
      end
    RB
    assert_includes err.message, "request_upload takes the file part's name"
  end

  def test_action_text_html_comes_with_scraper_in_source_attribute_order
    out = files(<<~RB)
      post "/post" do
        text(action_text_html(request_body))
      end
    RB
    assert_includes out["src/main.rs"], "fn axum_dsl_action_text_html(html: &str) -> String"
    assert_includes out["src/main.rs"], "::scraper::Html::parse_fragment(stripped).root_element().inner_html()"
    assert_includes out["Cargo.toml"], 'scraper = { version = "0.20", features = ["deterministic"] }'
  end

  def test_action_text_html_takes_a_string
    err = assert_raises(AxumDsl::CompileError) { files(<<~RB) }
      get "/x" do
        text(action_text_html(1))
      end
    RB
    assert_includes err.message, "action_text_html takes a string"
  end
end

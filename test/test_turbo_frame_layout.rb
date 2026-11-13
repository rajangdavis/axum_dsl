# frozen_string_literal: true

# `set :turbo_frame_layout, :frame`: turbo-rails renders a Turbo-Frame request in its frame layout, so a render with
# another layout answers either way on the header.
#
#   ruby -Ilib test/test_turbo_frame_layout.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestTurboFrameLayout < Minitest::Test
  def main(extra, layout_kw = "")
    Dir.mktmpdir("frame") do |dir|
      Dir.mkdir(File.join(dir, "views"))
      File.write(File.join(dir, "views", "app.html"), "<html><title>{{ title }}</title><body>{{ yield }}</body></html>\n")
      File.write(File.join(dir, "views", "frame.html"), "<html><head>{{ yield :head }}</head><body>{{ yield }}</body></html>\n")
      File.write(File.join(dir, "views", "page.html"), "<p>hi</p>\n")
      file = File.join(dir, "app.axum.rb")
      File.write(file, <<~RB)
        server "frame", version: "0.1.0"
        set :layout, :app
        #{extra}
        get "/" do
          render :page#{layout_kw}, locals: { title: "T" }
        end
      RB
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def test_a_frame_request_gets_the_frame_layout
    out = main("set :turbo_frame_layout, :frame")
    assert_includes out, "if axum_dsl_turbo_frame_request(&__headers) { ::axum::response::Html("
    assert_includes out, "fn axum_dsl_turbo_frame_request("
  end

  def test_frame_layout_false_keeps_the_one_layout
    out = main("set :turbo_frame_layout, :frame", ", frame_layout: false")
    refute_includes out, "axum_dsl_turbo_frame_request(&__headers)"
  end

  def test_frame_layout_false_needs_the_setting
    err = assert_raises(AxumDsl::CompileError) { main("", ", frame_layout: false") }
    assert_includes err.message, "needs `set :turbo_frame_layout`"
  end

  def test_without_it_a_render_has_one_layout
    refute_includes main(""), "axum_dsl_turbo_frame_request(&__headers)"
  end
end

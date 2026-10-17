# frozen_string_literal: true

# `static ... digest: true` and the `{{ asset_path "name" }}` marker (docs/views.md), asserted on the emitted
# crate: the fingerprinted file name, the bytes copied under it, the URL a view writes, and the refusals. No
# cargo and no HTTP; test/e2e_assets.sh fetches the fingerprinted path from the running service.
#
#   ruby -Ilib test/test_assets.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestAssets < Minitest::Test
  HEAD = <<~RB
    server "assets", version: "0.1.0"
  RB

  def compile_files(body, views: {}, extra: {}, head: HEAD)
    Dir.mktmpdir("assets") do |dir|
      (views.to_a + extra.to_a).each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "assets.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def refusal(body, views: {}, extra: {}, head: HEAD)
    error = assert_raises(AxumDsl::CompileError) { compile_files(body, views: views, extra: extra, head: head) }
    error.message
  end

  def page(name)
    { "views/home.html" => "<link href='{{ asset_path \"#{name}\" }}'>\n" }
  end

  CSS = "body { color: #123; }\n"

  def test_the_digest_names_the_copied_file_and_the_view_writes_the_same_url
    digest = AxumDsl.short_digest(CSS)
    files = compile_files(<<~RB, views: page("campfire.css"), extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public", digest: true

      get "/" do
        render :home
      end
    RB
    assert files.key?("public/campfire-#{digest}.css"), "the copied file is the fingerprinted name"
    refute files.key?("public/campfire.css"), "the undigested name is not copied, so it cannot be served"
    assert_equal CSS, files["public/campfire-#{digest}.css"], "the bytes are the file's own"
    assert_includes files["src/main.rs"], "/assets/campfire-#{digest}.css"
    assert_includes files["src/main.rs"], 'ServeDir::new("public")', "the mount still serves the copied directory"
  end

  def test_a_nested_file_keeps_its_folder_in_the_url_and_the_crate
    digest = AxumDsl.short_digest("a{}\n")
    files = compile_files(<<~RB, views: page("css/app.css"), extra: { "public/css/app.css" => "a{}\n" })
      static "/assets", dir: "public", digest: true

      get "/" do
        render :home
      end
    RB
    assert files.key?("public/css/app-#{digest}.css")
    assert_includes files["src/main.rs"], "/assets/css/app-#{digest}.css"
  end

  def test_without_digest_the_paths_are_the_files_own
    files = compile_files(<<~RB, extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public"

      get "/" do
        "ok"
      end
    RB
    assert files.key?("public/campfire.css")
    assert_equal CSS, files["public/campfire.css"]
    refute files.keys.any? { |path| path.include?("-") && path.end_with?(".css") && path != "public/campfire.css" },
           "no fingerprinted copy is made with the keyword off"
  end

  def test_the_name_follows_the_bytes
    one = AxumDsl.short_digest("a{}\n")
    two = AxumDsl.short_digest("b{}\n")
    refute_equal one, two
    body = <<~RB
      static "/assets", dir: "public", digest: true
      get "/" do
        "ok"
      end
    RB
    a = compile_files(body, extra: { "public/app.css" => "a{}\n" })
    b = compile_files(body, extra: { "public/app.css" => "b{}\n" })
    assert a.key?("public/app-#{one}.css")
    assert b.key?("public/app-#{two}.css")
    refute a.key?("public/app-#{two}.css")
  end

  def test_an_asset_path_needs_a_mounted_file
    message = refusal(<<~RB, views: page("nope.css"), extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public", digest: true

      get "/" do
        render :home
      end
    RB
    assert_includes message, "names no file under the \"/assets\" mount"
    assert_includes message, "campfire.css", "the refusal lists what the mount has"
  end

  def test_an_asset_path_needs_a_digest_mount
    message = refusal(<<~RB, views: page("campfire.css"), extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public"

      get "/" do
        render :home
      end
    RB
    assert_includes message, "needs a `static \"/assets\", dir: \"public\", digest: true` mount"
  end

  def test_two_digest_mounts_are_ambiguous
    message = refusal(<<~RB, views: page("x.css"), extra: { "a/x.css" => "a\n", "b/y.css" => "b\n" })
      static "/a", dir: "a", digest: true
      static "/b", dir: "b", digest: true

      get "/" do
        render :home
      end
    RB
    assert_includes message, "resolves against one fingerprinted mount"
    assert_includes message, "\"/a\", \"/b\""
  end

  def test_the_marker_takes_a_relative_double_quoted_path
    message = refusal(<<~RB, views: { "views/home.html" => "{{ asset_path campfire.css }}\n" }, extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public", digest: true

      get "/" do
        render :home
      end
    RB
    assert_includes message, "double-quoted string"

    message = refusal(<<~RB, views: page("/public/campfire.css"), extra: { "public/campfire.css" => CSS })
      static "/assets", dir: "public", digest: true

      get "/" do
        render :home
      end
    RB
    assert_includes message, "relative, without a leading /"
  end
end

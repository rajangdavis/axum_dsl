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
    digest = "08bc2f1d" # sha1("body { color: #123; }\n" + "1.0")[0, 8], Propshaft's rule
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
    digest = "83f3b409" # sha1("a{}\n" + "1.0")[0, 8]
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
    one = "83f3b409" # sha1("a{}\n" + "1.0")[0, 8]
    two = "febc8629" # sha1("b{}\n" + "1.0")[0, 8]
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

  APP_CSS = "@import url(\"base.css\");\nbody { background: url(img/dot.svg); }\n"
  BASE_CSS = "@import url(\"vars.css\");\n.a{}\n"
  VARS_CSS = ":root{--x:1}\n"
  DOT_SVG = "<svg/>\n"
  CHAIN = { "public/app.css" => APP_CSS, "public/base.css" => BASE_CSS, "public/vars.css" => VARS_CSS, "public/img/dot.svg" => DOT_SVG }.freeze
  CHAIN_BODY = <<~RB
    static "/assets", dir: "public", digest: true
    get "/" do
      "ok"
    end
  RB

  # The expected digests were computed with sha1sum over the files' bytes, then "1.0" (Propshaft 1.2.1's rule:
  # the file, then every file its CSS refers to depth first and once each, then the assets version). The same
  # rule gives Rails' _reset-9c3efd7b.css, lexxy-2876c58e.css, avatars-279376ab.css and composer-e490638a.css.
  def test_the_digest_covers_the_files_a_stylesheet_refers_to
    texts = { "app.css" => APP_CSS, "base.css" => BASE_CSS, "vars.css" => VARS_CSS, "img/dot.svg" => DOT_SVG }
    assert_equal "1b30d4f2", AxumDsl::Propshaft.digest("vars.css", texts)
    assert_equal "b336e7e8", AxumDsl::Propshaft.digest("img/dot.svg", texts)
    assert_equal "53e48027", AxumDsl::Propshaft.digest("base.css", texts)
    assert_equal "2d143daf", AxumDsl::Propshaft.digest("app.css", texts)
    assert_equal "e67e4717", AxumDsl::Propshaft.digest("x.css", { "x.css" => "a{}\n" }, "2"), "the assets version is the last bytes hashed"
  end

  def test_a_stylesheets_urls_name_the_digested_files
    files = compile_files(CHAIN_BODY, extra: CHAIN)
    assert_equal %(@import url("/assets/base-53e48027.css");\nbody { background: url("/assets/img/dot-b336e7e8.svg"); }\n),
                 files["public/app-2d143daf.css"]
    assert_equal %(@import url("/assets/vars-1b30d4f2.css");\n.a{}\n), files["public/base-53e48027.css"]
    assert_equal VARS_CSS, files["public/vars-1b30d4f2.css"]
    assert_equal DOT_SVG, files["public/img/dot-b336e7e8.svg"]
  end

  def test_references_that_are_not_files_of_the_mount_are_left_alone
    css = "a { background: url(data:image/png;base64,AAAA) url(https://x.test/a.png) url(//x.test/b.png) url(#frag) url(missing.png); }\n"
    files = compile_files(CHAIN_BODY, extra: { "public/app.css" => css })
    assert_equal css, files.find { |path, _| path.start_with?("public/app-") }[1]
  end

  def test_the_assets_version_changes_every_name
    files = compile_files(<<~RB, extra: { "public/app.css" => "a{}\n" })
      static "/assets", dir: "public", digest: true, version: "2"
      get "/" do
        "ok"
      end
    RB
    assert files.key?("public/app-e67e4717.css")
  end

  def test_a_version_needs_a_digest_mount
    assert_includes refusal(<<~RB, extra: { "public/app.css" => "a{}\n" }), "`version:` is the assets version of a `digest: true` mount"
      static "/assets", dir: "public", version: "2"
      get "/" do
        "ok"
      end
    RB
  end

  def test_a_mount_with_a_max_age_sends_its_headers_through_a_router_of_its_own
    main = compile_files(<<~RB, extra: { "public/app.css" => "a{}\n" })["src/main.rs"]
      static "/assets", dir: "public", digest: true, max_age: 2592000
      get "/" do
        "ok"
      end
    RB
    assert_includes main, "axum_dsl_static_headers_0"
    assert_includes main, '"max-age=2592000, public"'
    assert_includes main, 'headers.remove("accept-ranges")', "Propshaft answers whole files"
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

  # serve_file takes the same `skip:` as a route: the named filter steps aside for GET and HEAD of its path.
  def test_serve_file_skip_steps_the_filter_aside_for_its_path
    main = compile_files(<<~RB, extra: { "public/page.html" => "<p>hi</p>\n" })["src/main.rs"]
      before :authenticate do
        "continue"
      end

      serve_file "/page.html", from: "public/page.html", skip: [:authenticate]

      get "/" do
        text("ok")
      end
    RB
    assert_includes main, "axum_dsl_skip_match(\"/page.html\", path)"
    assert_includes main, "Method::GET && axum_dsl_skip_match(\"/page.html\""
    assert_includes main, "Method::HEAD && axum_dsl_skip_match(\"/page.html\""
  end

  def test_serve_file_skip_of_an_undeclared_filter_is_refused
    message = refusal(<<~RB, extra: { "public/page.html" => "<p>hi</p>\n" })
      serve_file "/page.html", from: "public/page.html", skip: [:nope]
    RB
    assert_includes message, "serve_file `/page.html` skips `:nope`, but no `before :nope` filter is declared"
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

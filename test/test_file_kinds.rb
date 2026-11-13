# frozen_string_literal: true

# The file kinds a use_dsl file may be (`fragment`, `model`, `controller`, with the name taken from the path), a
# current's `reader:` (current_user) and the `flash` declaration (redirect(..., notice:/alert:) and take_flash).
#
#   ruby -Ilib test/test_file_kinds.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestFileKinds < Minitest::Test
  # main.rs of the root `src` with `files` (relative path => text) written beside it.
  def emit(src, files = {})
    Dir.mktmpdir("kinds") do |dir|
      files.each do |rel, text|
        FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "app.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refused(src, files = {}) = assert_raises(AxumDsl::CompileError) { emit(src, files) }.message

  HEAD = <<~RB
    server "kinds", version: "0.1.0"
    database :sqlite, path: "k.sqlite3"
  RB

  MODEL = <<~RB
    model do
      record :Thing do
        field :id, :i64
      end
      query :thing, args: { id: :i64 }, returns: :Thing?, sql: "SELECT 1 AS id WHERE :id = 1"
      def thing_or_none(id)
        thing(id: id)
      end
    end
  RB

  CONTROLLER = <<~RB
    controller do
      before :guard, only: [:show]
      get "/things", action: :index do
        "all"
      end
      get "/things/one", action: :show do
        t = thing_or_none(1)
        t.nil? ? "none" : "one"
      end
      def guard
        return head(403) if thing_or_none(1).nil?
      end
    end
  RB

  def app(*includes) = HEAD + includes.map { |f| "use_dsl \"#{f}\"\n" }.join

  def test_a_model_and_a_controller_file_compile_and_the_controller_is_named_after_its_path
    main = emit(app("models/thing.axum.rb", "controllers/admin/things.axum.rb"),
                "models/thing.axum.rb" => MODEL, "controllers/admin/things.axum.rb" => CONTROLLER)
    assert_match(/def guard \(before filter\)/, main)
    # Two controllers named after the same path are refused as duplicates, so the name is the path's.
    msg = refused(app("controllers/admin/things.axum.rb", "x.axum.rb"),
                  "controllers/admin/things.axum.rb" => "controller do\nend\n", "x.axum.rb" => "controller \"Admin::Things\" do\nend\n")
    assert_includes msg, "duplicate controller \"Admin::Things\""
  end

  def test_a_named_model_and_controller_may_live_anywhere
    main = emit(app("lib/thing.axum.rb") + "get \"/one\" do\n  \"\#{one}\"\nend\n",
                "lib/thing.axum.rb" => "model \"Thing\" do\n  query :one, args: {}, returns: :i64, sql: \"SELECT 1\"\nend\n")
    assert_includes main, "SELECT 1"
  end

  def test_kind_refusals
    assert_includes refused(app("lib/thing.axum.rb"), "lib/thing.axum.rb" => "model do\nend\n"),
                    "`model do` takes its name from a file under models/"
    assert_includes refused(app("models/thing.axum.rb"), "models/thing.axum.rb" => "model do\n  get \"/x\" do\n    \"x\"\n  end\nend\n"),
                    "`get` is not allowed in `model`"
    assert_includes refused(app("controllers/things.axum.rb"),
                            "controllers/things.axum.rb" => "controller do\n  query :q, args: {}, returns: :i64, sql: \"SELECT 1\"\nend\n"),
                    "`query` is not allowed in `controller`"
    assert_includes refused(app("models/a.axum.rb", "lib/b.axum.rb"),
                            "models/a.axum.rb" => "model do\nend\n", "lib/b.axum.rb" => "model \"A\" do\nend\n"),
                    "duplicate model \"A\""
    assert_includes refused(app("x.axum.rb"), "x.axum.rb" => "model do\nend\nmodel do\nend\n"),
                    "expected exactly one top-level `fragment`, `model` or `controller` call"
  end

  COOKIES = <<~RB
    server "kinds", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
  RB

  CURRENT = <<~RB
    before :authenticate do
      return redirect("/login") if current_user.nil?
      "continue"
    end
    current :user, returns: :string?, required: :authenticate, reader: :current_user do
      cookie(:who)
    end
  RB

  def test_a_reader_is_the_current_it_names
    main = emit(COOKIES + CURRENT + "get \"/me\" do\n  current_user\nend\n")
    assert_match(/axum_dsl_require_current\(__currents\.user\.get_or_try_init/, main, "behind the filter a reader is the non-nil current")
    msg = refused(COOKIES + CURRENT + "get \"/me\", skip: [:authenticate] do\n  current_user || \"\"\nend\n")
    assert_includes msg, "is non-nil only after `before :authenticate`"
    assert_includes refused(COOKIES + CURRENT + "def current_user\n  1\nend\nget \"/\" do\n  \"x\"\nend\n"), "has the name of a def"
    assert_includes refused(COOKIES + CURRENT + "get \"/me\" do\n  current_user(1)\nend\n"), "current_user takes no arguments"
  end

  FLASH = <<~RB
    flash cookie: "_app_session", notice: { saved: "Saved" }, alert: { gone: "Gone" }
  RB

  def test_the_flash_writes_a_suffix_and_take_flash_reads_it_once
    main = emit(COOKIES + FLASH + <<~RB)
      get "/save" do
        redirect("/page", notice: :saved)
      end
      get "/page" do
        f = take_flash
        "\#{f.on} \#{f.alert} \#{f.text}"
      end
    RB
    assert_includes main, "fn axum_dsl_flash_split(value: &str) -> (String, AxumDslFlash)"
    assert_includes main, %((".saved", "saved", "Saved", false))
    assert_includes main, %((".gone", "gone", "Gone", true))
    assert_match(/__cookies\.push\(axum_dsl_set_cookie_raw\("_app_session", &format!\("\{\}\.saved", /, main)
    assert_match(/let \(__bare, __flash\) = axum_dsl_flash_split/, main)
  end

  def test_flash_refusals
    route = ->(body) { COOKIES + FLASH + "get \"/x\" do\n  #{body}\nend\n" }
    assert_includes refused(route.("redirect(\"/\", notice: :gone)")), "`notice: :gone` is not a flash notice (declared notices: saved)"
    assert_includes refused(route.("redirect(\"/\", alert: :nope)")), "`alert: :nope` is not a flash alert"
    assert_includes refused(route.("redirect(\"/\", notice: :saved, alert: :gone)")), "a redirect carries one flash message"
    assert_includes refused(COOKIES + "get \"/x\" do\n  f = take_flash\n  f.text\nend\n"), "take_flash needs a `flash cookie:"
    assert_includes refused(COOKIES + "flash cookie: \"_s\"\nget \"/\" do\n  \"x\"\nend\n"), "flash declares no message"
    assert_includes refused(COOKIES + FLASH + FLASH + "get \"/\" do\n  \"x\"\nend\n"), "duplicate `flash`"
  end
end

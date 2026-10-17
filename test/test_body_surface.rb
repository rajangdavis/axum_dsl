# frozen_string_literal: true

# The body surface has two halves that must not drift: what the compiler accepts, in AxumDsl::Body
# (BODY_CALLS, RESPONSE_HELPERS and ALLOWED_METHODS), and what bin/gen_rbi declares for Sorbet
# (BODY_SURFACE, and the rbi it writes). This is SPEC.md's L6 idea, for the body language: the
# generated rbi and the compiler's own table cannot disagree.
#
#   ruby -Ilib test/test_body_surface.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "axum_dsl"
load File.expand_path("../bin/gen_rbi", __dir__)

class TestBodySurface < Minitest::Test
  BODY = AxumDsl::Body
  EXE = File.expand_path("../exe/axum_dsl", __dir__)
  HEAD = <<~RB
    server "surface", version: "0.1.0"
    set :port, 8080
  RB

  # The compiler path the other emitted-text tests use: `axum_dsl check` proves the file compiles, then
  # the compiler's own reader and emitter give the Rust the assertions read.
  def compile(body, views: {}, head: HEAD)
    Dir.mktmpdir("surface") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "surface.axum.rb")
      File.write(file, head + body)
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      return AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def test_the_compiler_list_and_the_rbi_table_name_the_same_calls
    assert_equal BODY::BODY_CALLS.map(&:to_s).sort, BODY_SURFACE.keys.map(&:to_s).sort,
                 "Body::BODY_CALLS and BODY_SURFACE in bin/gen_rbi have drifted apart"
  end

  def test_the_response_helpers_are_body_calls
    BODY::RESPONSE_HELPERS.each do |helper|
      assert_includes BODY::BODY_CALLS, helper, "#{helper} is a response helper but not a body call"
    end
  end

  def test_a_name_is_either_a_call_or_a_method_on_a_value
    overlap = BODY::BODY_CALLS.map(&:to_s) & BODY::ALLOWED_METHODS
    assert_empty overlap, "#{overlap.join(', ')} appears in both BODY_CALLS and ALLOWED_METHODS"
  end

  def test_every_body_call_has_a_def_in_the_generated_rbi
    rbi = File.read(File.expand_path("../rbi/dsl.rbi", __dir__))
    BODY::BODY_CALLS.each do |name|
      assert_match(/^ *def #{Regexp.escape(name.to_s)}[\(;]/, rbi,
                   "#{name} is a body call but the rbi declares no `def #{name}`")
    end
  end

  def test_the_rbi_on_disk_is_current
    assert_equal RBI_TEXT, File.read(File.expand_path("../rbi/dsl.rbi", __dir__)),
                 "rbi/dsl.rbi is stale: run `make rbi` (or `ruby bin/gen_rbi`)"
  end

  # AX11 (a): `redirect` is a 302, not axum's `Redirect::to` (303), and it is still a :response value.
  def test_redirect_is_a_302_by_default
    main = compile(<<~RB)
      get "/x" do
        redirect("/session/new")
      end
    RB
    assert_includes main,
                    "{ let mut __redirect = ::axum::response::IntoResponse::into_response((::axum::http::StatusCode::FOUND, ()));"
    assert_includes main, "::axum::http::header::LOCATION"
    assert_includes main, "::axum::http::HeaderValue::from_str(\"/session/new\")"
    assert_includes main, "__redirect }", "the block is the response value, so a return can carry it"
    refute_includes main, "Redirect::to", "Redirect::to answers 303; redirect must answer 302"
  end

  # AX11 (a): `status:` names another redirect status, and only the five HTTP ones are accepted.
  def test_redirect_takes_a_redirect_status
    main = compile(<<~RB)
      get "/x" do
        redirect("/x", status: 303)
      end
    RB
    assert_includes main, "::axum::http::StatusCode::from_u16(303).unwrap()"
    assert_includes main, "::axum::http::header::LOCATION"
    refute_includes main, "Redirect::to"
  end

  # AX11 (b): a render's status rides on the value, so a `return` carries it, and locals still compose.
  def test_render_carries_a_status_on_the_value
    main = compile(<<~RB, views: { "views/session_new.html" => "<h1>{{ title }}</h1>\n" })
      get "/session/new" do
        return render(:session_new, status: 401, locals: { title: "Sign in" }) if false
        redirect("/")
      end
    RB
    assert_includes main, "(::axum::http::StatusCode::from_u16(401).unwrap(), ::axum::response::Html("
    assert_includes main, "Sign in", "the locals are still passed to the view"
  end

  # AX11 (b): html, text and json carry the status the same way; with no status they emit what they did.
  def test_text_html_and_json_carry_a_status_on_the_value
    main = compile(<<~RB)
      get "/html" do
        html("<h1>no</h1>", status: 401)
      end

      get "/text" do
        text("no", status: 401)
      end

      get "/json" do
        json("no", status: 401)
      end
    RB
    assert_includes main,
                    "(::axum::http::StatusCode::from_u16(401).unwrap(), ::axum::response::Html(\"<h1>no</h1>\".to_string()))"
    assert_includes main, "(::axum::http::StatusCode::from_u16(401).unwrap(), \"no\".to_string())"
    assert_includes main, "(::axum::http::StatusCode::from_u16(401).unwrap(), ::axum::Json(\"no\"))"

    plain = compile(<<~RB)
      get "/plain" do
        text("ok")
      end
    RB
    assert_includes plain, "::axum::response::IntoResponse::into_response(\"ok\".to_string())"
    refute_includes plain, "from_u16(401)", "no status: the helper emits exactly what it did before"
  end

  # AX11 (c): a bare execute/query call runs for its effect; it declares no local and its value is dropped.
  def test_a_bare_execute_and_query_may_stand_as_statements
    main = compile(<<~RB)
      database :sqlite, path: "surface.sqlite3"
      query :find_session, args: { token: :string }, returns: :string, sql: "SELECT user_agent FROM sessions WHERE token = :token"
      execute :end_session, args: { token: :string }, sql: "DELETE FROM sessions WHERE token = :token"

      get "/logout" do
        find_session(token: "t")
        end_session(token: "t")
        redirect("/session/new")
      end
    RB
    assert_includes main, "query_find_session(\"t\".to_string()).await?;", "the query runs as a statement"
    assert_includes main, "query_end_session(\"t\".to_string()).await?;", "the execute runs as a statement"
    refute_match(/let\s+(find_session|end_session)\b/, main, "a bare call declares no local")
    assert_includes main, "::axum::http::StatusCode::FOUND", "the route still ends in the redirect"
  end

  # AX11 (c): a redirect path is a literal, or a literal with numbers and bools interpolated, because the
  # path becomes the Location header; Campfire C1's `/rooms/#{room_id}` needs the numeric form.
  def test_redirect_paths_are_literal_or_numeric
    main = compile(<<~RB)
      params :Rooms do
        field :id, :i64, in: :path
      end

      get "/rooms/:id", params: :Rooms do
        redirect("/rooms/\#{params[:id]}")
      end

      get "/rooms_local/:id", params: :Rooms do
        room_id = params[:id]
        redirect("/rooms/\#{room_id}")
      end

      get "/literal" do
        redirect("/session/new")
      end
    RB
    assert_includes main, "::axum::http::HeaderValue::from_str(&format!(\"/rooms/{}\", id))"
    assert_includes main, "::axum::http::HeaderValue::from_str(&format!(\"/rooms/{}\", room_id))"
    assert_includes main, "::axum::http::HeaderValue::from_str(\"/session/new\")"
  end

  # AX11 (c): `status(...)` (the statement) and a helper's `status:` (on the value) may not meet in one
  # body; a body that uses only one of them still compiles.
  def test_status_statement_and_a_helper_status_compile_alone
    main = compile(<<~RB)
      get "/helper" do
        text("no", status: 401)
      end

      get "/statement" do
        status(401)
        text("no")
      end
    RB
    assert_includes main, "(::axum::http::StatusCode::from_u16(401).unwrap(), \"no\".to_string())"
    assert_includes main, "*__stated.status_mut() = ::axum::http::StatusCode::from_u16(401).unwrap();"
  end

  # AX12: a helper's `content_type:` rides on the returned response as its CONTENT_TYPE header,
  # with or without a `status:`; a body that writes neither emits exactly what it did before.
  def test_text_carries_a_content_type_on_the_value
    main = compile(<<~RB)
      get "/stream" do
        text("x", content_type: "text/vnd.turbo-stream.html")
      end
    RB
    assert_includes main,
                    "{ let mut __response = ::axum::response::IntoResponse::into_response(\"x\".to_string());"
    assert_includes main, "::axum::http::header::CONTENT_TYPE"
    assert_includes main, "::axum::http::HeaderValue::from_static(\"text/vnd.turbo-stream.html\")"
    assert_includes main, "__response }", "the block is the response value, so a return can carry it"
  end

  # render combines a content type with a status and locals.
  def test_render_carries_a_content_type_and_a_status
    main = compile(<<~RB, views: { "views/x.html" => "<h1>{{ title }}</h1>\n" })
      get "/x" do
        render :x, content_type: "text/html", status: 201, locals: { title: "Hi" }
      end
    RB
    assert_includes main,
                    "{ let mut __response = ::axum::response::IntoResponse::into_response(" \
                    "(::axum::http::StatusCode::from_u16(201).unwrap(), ::axum::response::Html("
    assert_includes main, "::axum::http::HeaderValue::from_static(\"text/html\")"
    assert_includes main, "Hi", "the locals are still passed to the view"
    assert_includes main, "__response }"
  end

  def test_a_helper_with_no_content_type_emits_the_old_shape
    main = compile(<<~RB)
      get "/plain" do
        text("ok")
      end
    RB
    assert_includes main, "::axum::response::IntoResponse::into_response(\"ok\".to_string())"
    refute_includes main, "CONTENT_TYPE", "no content_type: the helper emits exactly what it did before"
    refute_includes main, "__response"
  end
end

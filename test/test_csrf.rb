# frozen_string_literal: true

# use_layer :csrf (docs/sessions.md), asserted on the emitted Rust: the runtime, the signed cookie, the
# extension `{{ csrf_token }}` reads, the order behind :fetch_metadata, and the refusals. No cargo and no
# HTTP; test/e2e_csrf.sh drives the running service.
#
#   ruby -Ilib test/test_csrf.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestCsrf < Minitest::Test
  HEAD = <<~RB
    server "csrf", version: "0.1.0"
  RB

  COOKIES = <<~RB
    setting :secret_key, env: "SECRET_KEY_BASE"
    cookies secret: :secret_key
  RB

  FORM = "<input type=\"hidden\" name=\"authenticity_token\" value=\"{{ csrf_token }}\">\n"

  def compile_files(body, head: HEAD + COOKIES, views: {})
    Dir.mktmpdir("csrf") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "csrf.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def main(body, **kw) = compile_files(body, **kw)["src/main.rs"]

  def refusal(body, head: HEAD + COOKIES, views: {})
    error = assert_raises(AxumDsl::CompileError) { compile_files(body, head: head, views: views) }
    error.message
  end

  RENDER_FORM = <<~RB
    use_layer :csrf
    get "/form" do
      render :form
    end
  RB

  def form_rust
    main(RENDER_FORM, views: { "views/form.html" => FORM })
  end

  # --- the layer -----------------------------------------------------------------------------------------

  def test_the_layer_emits_the_runtime_and_refuses_a_write_without_a_matching_token
    rust = form_rust
    assert_includes rust, "async fn axum_dsl_csrf("
    assert_includes rust, ".layer(::axum::middleware::from_fn(axum_dsl_csrf))"
    assert_includes rust, 'const AXUM_DSL_CSRF_COOKIE: &str = "_axum_dsl_csrf";'
    assert_includes rust, 'const AXUM_DSL_CSRF_FIELD: &str = "authenticity_token";'
    assert_includes rust, 'const AXUM_DSL_CSRF_HEADER: &str = "x-csrf-token";'
    assert_includes rust, "axum_dsl_cookie(&request.headers(), AXUM_DSL_CSRF_COOKIE)",
                    "the cookie is the existing signed reader"
    assert_includes rust, 'axum_dsl_set_cookie(AXUM_DSL_CSRF_COOKIE, &token, true, "Lax", false, None)',
                    "a missing token is minted and set HttpOnly, SameSite=Lax"
    assert_includes rust, "axum_dsl_apply_cookies(&mut response, &[cookie]);"
    assert_includes rust, "axum_dsl_ct_eq(value.as_bytes(), token.as_bytes())",
                    "the comparison is the constant-time one"
    assert_includes rust, '"CSRF token missing or invalid"'
    assert_includes rust, "*refused.status_mut() = ::axum::http::StatusCode::FORBIDDEN;"
    assert_includes rust, "application/x-www-form-urlencoded", "a form POST's field is read out of the body"
    assert_includes rust, "::axum::body::to_bytes(body, AXUM_DSL_CSRF_BODY_LIMIT)",
                    "and the body is rebuilt for the Form extractor"
    assert_includes rust, "::axum::http::Request::from_parts(parts, ::axum::body::Body::from(bytes))"
  end

  def test_the_view_marker_reads_the_request_extension_and_no_local_is_needed
    rust = form_rust
    assert_includes rust, "::axum::Extension(__csrf): ::axum::Extension<AxumDslCsrfToken>"
    assert_includes rust, "__csrf.0.as_str()"
    refute_includes rust, "locals: { csrf_token", "the token is not a local"
  end

  def test_a_route_that_never_writes_the_marker_takes_no_extension_and_the_struct_is_not_dead_code
    rust = main("use_layer :csrf\nget \"/x\" do\n  \"ok\"\nend\n")
    refute_includes rust, "Extension(__csrf)"
    assert_includes rust, "struct AxumDslCsrfToken(String);"
    assert_includes rust, "#[allow(dead_code)]", "the token field is unread when no view writes it"
  end

  def test_the_csrf_cookie_brings_the_cookie_runtime_and_rand_only_when_the_layer_is_on
    files = compile_files(RENDER_FORM, views: { "views/form.html" => FORM })
    assert_includes files["src/main.rs"], "fn axum_dsl_cookie_verify("
    assert_includes files["src/main.rs"], "fn axum_dsl_cookie_sign("
    assert_includes files["src/main.rs"], "fn axum_dsl_random_token()"
    assert_includes files["Cargo.toml"], "\nhmac = "
    assert_includes files["Cargo.toml"], "\nrand = \"0.9\""

    plain = compile_files("get \"/x\" do\n  \"ok\"\nend\n", head: HEAD)
    refute_includes plain["src/main.rs"], "axum_dsl_csrf"
    refute_includes plain["src/main.rs"], "AxumDslCsrfToken"
    refute_includes plain["Cargo.toml"], "\nrand = "
  end

  def test_fetch_metadata_stays_the_first_line_guard
    rust = main(<<~RB)
      use_layer :fetch_metadata
      use_layer :csrf
      get "/x" do
        "ok"
      end
    RB
    csrf = rust.index(".layer(::axum::middleware::from_fn(axum_dsl_csrf))")
    fetch = rust.index(".layer(::axum::middleware::from_fn(axum_dsl_fetch_metadata))")
    refute_nil csrf
    refute_nil fetch
    assert_operator csrf, :<, fetch, "the last layer added is the outermost, so Fetch Metadata runs first"
  end

  def test_a_before_filter_that_renders_the_marker_reads_the_extension_too
    rust = main(<<~RB, views: { "views/form.html" => FORM })
      use_layer :csrf
      before do
        render :form
      end
      get "/x" do
        "ok"
      end
    RB
    assert_includes rust, "let __csrf = request.extensions().get::<AxumDslCsrfToken>().cloned().unwrap_or_default();"
  end

  # --- refusals ------------------------------------------------------------------------------------------

  def test_the_layer_needs_the_cookies_declaration_and_its_key
    message = refusal("use_layer :csrf\nget \"/x\" do\n  \"ok\"\nend\n", head: HEAD)
    assert_includes message, "needs `cookies secret: :setting_name`"
    assert_includes message, "the token is a signed cookie"
  end

  def test_the_layer_takes_no_keywords
    message = refusal("use_layer :csrf, secs: 5\nget \"/x\" do\n  \"ok\"\nend\n")
    assert_includes message, "`use_layer :csrf` takes no keywords"
  end

  def test_the_marker_needs_the_layer
    message = refusal("get \"/form\" do\n  render :form\nend\n", views: { "views/form.html" => FORM })
    assert_includes message, "needs `use_layer :csrf`"
  end

  def test_a_layout_that_writes_the_marker_takes_the_extension_too
    views = { "views/home.html" => "home\n",
              "views/app.html" => "<html>{{ csrf_token }}{{ yield }}</html>\n" }
    rust = main(<<~RB, views: views)
      use_layer :csrf
      set :layout, :app
      get "/" do
        render :home
      end
    RB
    assert_includes rust, "::axum::Extension(__csrf): ::axum::Extension<AxumDslCsrfToken>"
    assert_includes rust, "__csrf.0.as_str()", "a layout is compiled with its child, so its marker needs the token too"
  end

  def test_the_marker_is_not_for_a_filter_without_a_request
    message = refusal("use_layer :csrf\nnot_found do\n  render :form\nend\n", views: { "views/form.html" => FORM })
    assert_includes message, "runs without one"
  end

  def test_the_marker_takes_no_filter
    message = refusal(RENDER_FORM, views: { "views/form.html" => "{{ csrf_token|raw }}\n" })
    assert_includes message, "`{{ csrf_token }}` takes no filter"
  end
end
